import SwiftUI
import ImageIO

/// 缩略图：录屏用自带的 PNG；截图从文件按需生成小图，避免把原图整张解码进内存。
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
        if let data = item.thumbnailPNG { return NSImage(data: data) }
        let url = item.url
        return await Task.detached(priority: .utility) { () -> NSImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: .zero)
        }.value
    }
}

/// 底部「最近截图」：横向滚动，最新在左；悬停出现「拷贝」「在 Finder 中显示」；可拖到别的 App。
struct RecentCapturesStrip: View {
    let store: CaptureStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("最近截图").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("清空") { store.clear() }
                    .buttonStyle(.borderless).font(.caption)
                    .foregroundStyle(Theme.accent)
                    .disabled(store.recent.isEmpty)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if store.recent.isEmpty {
                Text("暂无截图").font(.callout).foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 8) {
                        ForEach(store.recent) { RecentCell(item: $0, store: store) }
                    }
                    .padding(.horizontal, 12).padding(.bottom, 10)
                }
            }
        }
    }
}

private struct RecentCell: View {
    let item: CaptureItem
    let store: CaptureStore
    @State private var hovering = false

    var body: some View {
        let exists = store.fileExists(item)
        CaptureThumbnail(item: item)
            .frame(width: 72, height: 96)
            .opacity(exists ? 1 : 0.35)
            .overlay {
                if !exists {
                    Text("文件已删除").font(.caption).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                } else if hovering {
                    VStack(spacing: 4) {
                        Spacer()
                        actions(exists: exists)
                    }
                    .padding(4)
                }
            }
            .onHover { hovering = $0 }
            .onDrag {
                // 文件不存在时 contentsOf 返回 nil，给出空提供者而不是崩溃。
                NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
            }
            .help(item.url.lastPathComponent)
    }

    private func actions(exists: Bool) -> some View {
        VStack(spacing: 2) {
            Button("拷贝") { store.copy(item) }
            Button("在 Finder 中显示") { store.reveal(item) }
        }
        .font(.caption2)
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.textPrimary)
        .disabled(!exists)
        .padding(3)
        .background(Theme.panel.opacity(0.92), in: RoundedRectangle(cornerRadius: 5))
    }
}
