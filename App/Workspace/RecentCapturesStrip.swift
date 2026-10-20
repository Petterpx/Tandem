import MediaKit
import SwiftUI

/// 缩略图：只用记录自带的小图（保存时已生成），没有则显示占位图标；不再从文件解码整图。
struct CaptureThumbnail: View {
    let item: CaptureItem
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Theme.canvas
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: item.kind == .recording ? "film" : "photo")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: item.id) { image = await Self.load(item) }
    }

    private static func load(_ item: CaptureItem) async -> NSImage? {
        item.thumbnailPNG.flatMap { NSImage(data: $0) }
    }
}

/// 最近截图条的文案与尺寸。
enum CaptureText {
    /// 新截的一张在标签前显示蓝点的时长。
    static let freshInterval: TimeInterval = 3

    /// 「设备名 · HH:mm」。
    static func tileLabel(_ item: CaptureItem, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute], from: item.date)
        return "\(item.deviceName) · " + String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// 在 box×box 内按原图比例缩放；没有尺寸时按竖屏 41×box。
    static func thumbSize(pixelWidth: Int?, pixelHeight: Int?, box: CGFloat) -> CGSize {
        guard let w = pixelWidth, let h = pixelHeight, w > 0, h > 0 else { return CGSize(width: 41, height: box) }
        // 先乘后除，1080×2400 正好得到 41.4
        return w >= h
            ? CGSize(width: box, height: box * CGFloat(h) / CGFloat(w))
            : CGSize(width: box * CGFloat(w) / CGFloat(h), height: box)
    }

    static func isFresh(date: Date, now: Date) -> Bool {
        now.timeIntervalSince(date) < freshInterval
    }

    /// 蓝点只给最新的一项，且只在加入后 3 秒内。
    static func showsFreshDot(_ item: CaptureItem, newest: CaptureItem?, now: Date) -> Bool {
        item.id == newest?.id && isFresh(date: item.date, now: now)
    }
}

/// 磁贴缩略图缓存：按记录 id 存解码好的图与显示尺寸，选中变化或时间刷新时不再重复解码。
@MainActor enum TileThumbCache {
    final class Entry {
        let image: NSImage?
        let size: CGSize

        init(image: NSImage?, size: CGSize) {
            self.image = image
            self.size = size
        }
    }

    private static let cache: NSCache<NSUUID, Entry> = {
        let cache = NSCache<NSUUID, Entry>()
        cache.countLimit = 2 * CaptureStore.recentLimit
        return cache
    }()

    /// 记录不可变，同一 id 的缩略图不会变。
    static func entry(for item: CaptureItem, box: CGFloat) -> Entry {
        let key = item.id as NSUUID
        if let hit = cache.object(forKey: key) { return hit }
        let pixel = item.thumbnailPNG.flatMap(ScreenshotEncoder.pixelSize(ofPNG:))
        let entry = Entry(
            image: item.thumbnailPNG.flatMap(NSImage.init(data:)),
            size: CaptureText.thumbSize(pixelWidth: pixel?.width, pixelHeight: pixel?.height, box: box))
        cache.setObject(entry, forKey: key)
        return entry
    }
}

/// 底部「最近截图」：横向胶片条，最新在左；悬停浮出拷贝 / 在 Finder 中显示 / 更多；可拖到别的 App。
/// 单击磁贴选中并让条获得焦点，之后空格 Quick Look、⌘C 拷贝、← / → 切换、Esc 取消；投屏有焦点时按键照常发给手机。
struct RecentCapturesStrip: View {
    let store: CaptureStore

    @State private var model: RecentStripModel
    @FocusState private var stripFocused: Bool
    /// 判断「新截」用的时间：最新一项加入 3 秒后刷新，蓝点随之消失。
    @State private var now = Date()

    init(store: CaptureStore, quickLook: QuickLookHooks = .live) {
        self.store = store
        _model = State(initialValue: RecentStripModel(store: store, quickLook: quickLook))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RecentCapturesHeader(count: store.recent.count) { store.clear() }
            if store.recent.isEmpty {
                Text("本次会话还没有截图或录屏")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                strip
            }
        }
        .onChange(of: store.recent.map(\.id)) { model.listChanged() }
        .task(id: store.recent.first?.id) {
            guard let newest = store.recent.first else { return }
            let remaining = CaptureText.freshInterval - Date().timeIntervalSince(newest.date)
            if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { now = Date() }
        }
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                RecentTiles(items: store.recent, store: store, selectedID: model.selectedID, now: now) { id in
                    model.select(id)
                    stripFocused = true
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($stripFocused)
            .onKeyPress(.space) { model.space() }
            .onKeyPress(.leftArrow) { model.move(-1) }
            .onKeyPress(.rightArrow) { model.move(1) }
            .onKeyPress(.escape) { model.escape() }
            // 键盘或预览面板里切换选中时滚到可见
            .onChange(of: model.selectedID) { _, id in
                if let id { proxy.scrollTo(id) }
            }
            // ⌘C 会先被「编辑 › 拷贝」菜单吃掉，到不了 onKeyPress；窗口内启用的快捷键按钮排在菜单之前。
            // 只在截图条有焦点且有选中时启用，其余时候 ⌘C 照常交给菜单（输入框、投屏）。
            .background {
                Button("拷贝选中项") { model.copy() }
                    .buttonStyle(TandemButtonStyle(.link))
                    .keyboardShortcut("c", modifiers: .command)
                    .disabled(!stripFocused || model.selectedID == nil)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// 「最近截图」头部：高 38，标题 + 数量徽标，尾部「清空」。
struct RecentCapturesHeader: View {
    let count: Int
    let onClear: () -> Void

    var body: some View {
        SectionHeader("最近截图", badge: Chip("\(count)", tone: .count)) {
            Button("清空", action: onClear)
                .buttonStyle(TandemButtonStyle(.link))
                .disabled(count == 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }
}

/// 磁贴条（ScrollView 里面的部分），单独拆出来供快照渲染。
struct RecentTiles: View {
    let items: [CaptureItem]
    let store: CaptureStore
    let selectedID: UUID?
    /// 判断「新截」的当前时间。
    let now: Date
    let onSelect: (UUID) -> Void

    init(
        items: [CaptureItem], store: CaptureStore, selectedID: UUID? = nil, now: Date = Date(),
        onSelect: @escaping (UUID) -> Void = { _ in }
    ) {
        self.items = items
        self.store = store
        self.selectedID = selectedID
        self.now = now
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(items) { item in
                RecentTileCell(
                    item: item, store: store, selected: item.id == selectedID,
                    fresh: CaptureText.showsFreshDot(item, newest: items.first, now: now), onSelect: onSelect)
                    .id(item.id)
            }
        }
        .padding(.top, 4)
        .padding(.horizontal, 16)
    }
}

/// 一格磁贴的状态：悬停、删除确认；外观交给 `RecentTile`。
private struct RecentTileCell: View {
    let item: CaptureItem
    let store: CaptureStore
    let selected: Bool
    let fresh: Bool
    let onSelect: (UUID) -> Void

    @State private var hovered = false
    @State private var confirmingTrash = false
    @State private var trashError: String?

    var body: some View {
        let exists = store.fileExists(item)
        RecentTile(
            item: item, store: store, exists: exists, hovered: hovered, selected: selected,
            fresh: fresh, onTrash: { confirmingTrash = true })
            .contentShape(Rectangle())
            .onHover { hovered = $0 }
            .onTapGesture { onSelect(item.id) }
            .onDrag {
                // 文件不存在时 contentsOf 返回 nil，给出空提供者而不是崩溃。
                NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
            }
            .contextMenu { RecentTile.menu(item: item, store: store, exists: exists) { confirmingTrash = true } }
            // 浮出的工具条与阴影盖住相邻磁贴
            .zIndex(hovered ? 1 : 0)
            .help(item.url.lastPathComponent)
            .confirmationDialog("将 \(item.url.lastPathComponent) 移到废纸篓？", isPresented: $confirmingTrash, titleVisibility: .visible) {
                Button("移到废纸篓", role: .destructive) {
                    do {
                        try store.trash(item)
                    } catch {
                        trashError = error.localizedDescription
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .alert("无法移到废纸篓", isPresented: Binding(get: { trashError != nil }, set: { if !$0 { trashError = nil } })) {
                Button("好") {}
            } message: {
                Text(trashError ?? "")
            }
    }
}

/// 一格磁贴的外观：缩略图（或录屏块、已删除占位）、标签、悬停工具条。悬停态由调用方给出，快照可直接传 true。
struct RecentTile: View {
    static let box: CGFloat = 92

    let item: CaptureItem
    let store: CaptureStore
    let exists: Bool
    var hovered = false
    var selected = false
    var fresh = false
    var onTrash: () -> Void = {}

    /// 文件已删除时不浮起、不出工具条。
    private var lifted: Bool { hovered && exists }

    var body: some View {
        VStack(spacing: 7) {
            thumbnail
            label
        }
        .frame(width: Self.box)
        .opacity(exists ? 1 : 0.55)
        .overlay(alignment: .top) {
            if lifted {
                toolbar
                    .fixedSize()
                    .offset(y: 74)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: lifted)
    }

    /// 「更多」菜单与右键菜单共用。
    @ViewBuilder
    static func menu(item: CaptureItem, store: CaptureStore, exists: Bool, onTrash: @escaping () -> Void) -> some View {
        if exists {
            Button("拷贝") { store.copy(item) }
            Button("在 Finder 中显示") { store.reveal(item) }
            Button(item.kind == .screenshot ? "用「预览」打开" : "用默认应用打开") { store.open(item) }
            Divider()
        }
        Button("从列表移除") { store.remove(item) }
        if exists {
            Button("删除文件…", role: .destructive, action: onTrash)
        }
    }

    // MARK: 缩略图

    private var thumbnail: some View {
        let thumb = TileThumbCache.entry(for: item, box: Self.box)
        let shape = RoundedRectangle(cornerRadius: 7)
        return thumbnailContent(thumb.image)
            .frame(width: thumb.size.width, height: thumb.size.height)
            .clipShape(shape)
            .overlay {
                if exists {
                    shape.strokeBorder(Theme.border, lineWidth: 1)
                } else {
                    shape.strokeBorder(Theme.dashed, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                }
            }
            .overlay {
                // 悬停或选中：外圈 2 px 蓝边
                if lifted || selected {
                    RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.accent, lineWidth: 2).padding(-2)
                }
            }
            .shadow(color: lifted ? Theme.shadowDeep.opacity(0.16) : .clear, radius: 14, y: 6)
            .offset(y: lifted ? -2 : 0)
            .frame(width: Self.box, height: Self.box)
    }

    @ViewBuilder private func thumbnailContent(_ image: NSImage?) -> some View {
        if !exists {
            ZStack {
                Theme.titleBar
                Image(systemName: "trash").font(.system(size: 16)).foregroundStyle(Theme.textSecondary)
            }
        } else if item.kind == .recording {
            ZStack {
                Theme.bezel
                Circle()
                    .fill(Theme.onVideo.opacity(0.18))
                    .frame(width: 22, height: 22)
                    .overlay(Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(Theme.onVideo))
                Text(CaptureButtons.clock(item.duration ?? 0))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.codeDarkText)
                    .frame(maxWidth: .infinity)
                    .frame(height: 14)
                    .background(Capsule().fill(Theme.videoBackground.opacity(0.55)))
                    .padding(.horizontal, 4)
                    .padding(.bottom, 5)
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }
        } else if let image {
            Image(nsImage: image).resizable().scaledToFill()
        } else {
            ZStack {
                Theme.titleBar
                Image(systemName: "photo").foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: 标签与工具条

    private var label: some View {
        HStack(spacing: 4) {
            if fresh && exists {
                Circle().fill(Theme.accent).frame(width: 5, height: 5)
            }
            Text(exists ? CaptureText.tileLabel(item) : "文件已删除")
                .tandemText(.meta)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
    }

    private var toolbar: some View {
        let shape = RoundedRectangle(cornerRadius: 15)
        return HStack(spacing: 2) {
            toolButton("doc.on.doc", help: "拷贝") { store.copy(item) }
            toolButton("folder", help: "在 Finder 中显示") { store.reveal(item) }
            MoreMenuButton { Self.menu(item: item, store: store, exists: exists, onTrash: onTrash) }
        }
        // 内边距 2 + 1 px 描边，总高 30
        .padding(3)
        .background(shape.fill(Theme.card))
        .overlay(shape.strokeBorder(Theme.cardBorder, lineWidth: 1))
        .shadow(color: Theme.shadowDeep.opacity(0.16), radius: 14, y: 6)
    }

    private func toolButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
        }
        .buttonStyle(TandemButtonStyle(.ghostIcon, height: 24, width: 26, radius: 12))
        .help(help)
    }
}

/// 工具条里的「更多」：26×24 的下拉菜单，悬停时出现底色，与另两个图标按钮一致。
private struct MoreMenuButton<Items: View>: View {
    @ViewBuilder let items: () -> Items
    @State private var hovered = false

    var body: some View {
        Menu(content: items) {
            Image(systemName: "ellipsis").font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 26, height: 24)
        .background(RoundedRectangle(cornerRadius: 12).fill(hovered ? Theme.controlHover : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onHover { hovered = $0 }
        .help("更多")
    }
}
