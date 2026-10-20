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
}

/// 截图条的按键逻辑（纯值类型）：选中、空格预览、⌘C 拷贝、← / → 切换、Esc 取消。
struct RecentStripKeys {
    enum KeyAction: Equatable {
        case none
        /// 预览该项；下标是它在列表里的位置。
        case preview(URL, Int)
        case copy(CaptureItem)
    }

    private(set) var items: [CaptureItem]
    var selectedID: UUID?
    /// 文件已删除的项：可以选中，但空格与 ⌘C 不做事。
    var missingIDs: Set<UUID>

    init(items: [CaptureItem], selectedID: UUID?, missingIDs: Set<UUID> = []) {
        self.items = items
        self.selectedID = selectedID
        self.missingIDs = missingIDs
    }

    var selectedIndex: Int? {
        selectedID.flatMap { id in items.firstIndex { $0.id == id } }
    }

    /// 选中且文件还在的项。
    private var available: (item: CaptureItem, index: Int)? {
        guard let index = selectedIndex, !missingIDs.contains(items[index].id) else { return nil }
        return (items[index], index)
    }

    func space() -> KeyAction {
        available.map { .preview($0.item.url, $0.index) } ?? .none
    }

    func copy() -> KeyAction {
        available.map { .copy($0.item) } ?? .none
    }

    mutating func move(_ step: Int) {
        selectedID = AppPolicy.adjacentID(items.map(\.id), from: selectedID, step: step)
    }

    mutating func escape() {
        selectedID = nil
    }

    /// 列表变化后，选中项不在了就清空选中。
    mutating func update(items: [CaptureItem]) {
        self.items = items
        if selectedIndex == nil { selectedID = nil }
    }
}

/// 截图条调用 Quick Look 的入口，可换成假实现。
struct QuickLookHooks {
    /// 已打开则关闭，否则预览第 index 项；面板里按 ← / → 时回调 onMove(∓1 / ±1)。
    var toggle: @MainActor (_ urls: [URL], _ index: Int, _ onMove: @escaping (Int) -> Void) -> Void
    var select: @MainActor (_ index: Int) -> Void
    var close: @MainActor () -> Void
    var isVisible: @MainActor () -> Bool

    @MainActor static var live: QuickLookHooks {
        let controller = QuickLookController.shared
        return QuickLookHooks(
            toggle: { urls, index, onMove in
                controller.onMove = onMove
                controller.toggle(urls: urls, index: index)
            },
            select: { controller.select(index: $0) },
            close: { controller.close() },
            isVisible: { controller.isVisible })
    }
}

/// 底部「最近截图」：横向胶片条，最新在左；悬停浮出拷贝 / 在 Finder 中显示 / 更多；可拖到别的 App。
/// 单击磁贴选中并让条获得焦点，之后空格 Quick Look、⌘C 拷贝、← / → 切换、Esc 取消；投屏有焦点时按键照常发给手机。
struct RecentCapturesStrip: View {
    let store: CaptureStore
    var quickLook: QuickLookHooks = .live

    @State private var selectedID: UUID?
    @FocusState private var stripFocused: Bool
    /// 判断「新截」用的时间：最新一项加入 3 秒后刷新，蓝点随之消失。
    @State private var now = Date()

    private var keys: RecentStripKeys {
        RecentStripKeys(
            items: store.recent, selectedID: selectedID,
            missingIDs: Set(store.recent.filter { !store.fileExists($0) }.map(\.id)))
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
        .onChange(of: store.recent.map(\.id)) {
            // 列表变了，预览面板里的下标就不再对应；选中项被移除时一并清空选中
            quickLook.close()
            var k = keys
            k.update(items: store.recent)
            selectedID = k.selectedID
        }
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
                RecentTiles(items: store.recent, store: store, selectedID: selectedID, now: now) { id in
                    select(id)
                    stripFocused = true
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($stripFocused)
            .onKeyPress(.space) { space(proxy) }
            .onKeyPress(.leftArrow) { move(-1, proxy) }
            .onKeyPress(.rightArrow) { move(1, proxy) }
            .onKeyPress(.escape) { escape() }
            // ⌘C 会先被「编辑 › 拷贝」菜单吃掉，到不了 onKeyPress；窗口内启用的快捷键按钮排在菜单之前。
            // 只在截图条有焦点且有选中时启用，其余时候 ⌘C 照常交给菜单（输入框、投屏）。
            .background {
                Button("拷贝选中项") {
                    if case .copy(let item) = keys.copy() { store.copy(item) }
                }
                .buttonStyle(TandemButtonStyle(.link))
                .keyboardShortcut("c", modifiers: .command)
                .disabled(!stripFocused || selectedID == nil)
                .opacity(0)
                .accessibilityHidden(true)
            }
        }
    }

    private func select(_ id: UUID) {
        selectedID = id
        if quickLook.isVisible(), let index = store.recent.firstIndex(where: { $0.id == id }) { quickLook.select(index) }
    }

    private func space(_ proxy: ScrollViewProxy) -> KeyPress.Result {
        if quickLook.isVisible() {
            quickLook.close()
            return .handled
        }
        guard case .preview(_, let index) = keys.space() else { return .ignored }
        quickLook.toggle(store.recent.map(\.url), index) { step in _ = move(step, proxy) }
        return .handled
    }

    private func move(_ step: Int, _ proxy: ScrollViewProxy) -> KeyPress.Result {
        var k = keys
        k.move(step)
        guard let id = k.selectedID else { return .ignored }
        selectedID = id
        proxy.scrollTo(id)
        if quickLook.isVisible(), let index = k.selectedIndex { quickLook.select(index) }
        return .handled
    }

    private func escape() -> KeyPress.Result {
        if quickLook.isVisible() {
            quickLook.close()
            return .handled
        }
        guard selectedID != nil else { return .ignored }
        selectedID = nil
        return .handled
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
                RecentTileCell(item: item, store: store, selected: item.id == selectedID, now: now, onSelect: onSelect)
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
    let now: Date
    let onSelect: (UUID) -> Void

    @State private var hovered = false
    @State private var confirmingTrash = false
    @State private var trashError: String?

    var body: some View {
        let exists = store.fileExists(item)
        RecentTile(
            item: item, store: store, exists: exists, hovered: hovered, selected: selected,
            fresh: CaptureText.isFresh(date: item.date, now: now),
            onTrash: { confirmingTrash = true })
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
        let pixel = item.thumbnailPNG.flatMap(ScreenshotEncoder.pixelSize(ofPNG:))
        let size = CaptureText.thumbSize(pixelWidth: pixel?.width, pixelHeight: pixel?.height, box: Self.box)
        let shape = RoundedRectangle(cornerRadius: 7)
        return thumbnailContent
            .frame(width: size.width, height: size.height)
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

    @ViewBuilder private var thumbnailContent: some View {
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
        } else if let image = item.thumbnailPNG.flatMap(NSImage.init(data:)) {
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
