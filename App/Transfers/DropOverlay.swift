import SwiftUI
import UniformTypeIdentifiers

/// 拖放的接收规则：APK 需要 `apps` 能力，其他文件与文件夹需要 `files` 能力。
enum DropPlan {
    static func isAPK(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "apk" && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
    }

    /// 按能力过滤，保持顺序；全被过滤掉时为空（拒绝这次放下）。
    static func accepted(_ urls: [URL], canInstall: Bool, canPush: Bool) -> [URL] {
        urls.filter { isAPK($0) ? canInstall : canPush }
    }

    /// 异步读出拖入项的路径，保持顺序，读不出的跳过。
    @MainActor static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            }
            if let url { urls.append(url) }
        }
        return urls
    }

    /// 悬停提示：按拖入项的文件名（APK 与其他）与设备能力给出可接收的操作；为空表示拒绝。
    static func hint(forNames names: [String], canInstall: Bool, canPush: Bool) -> [String] {
        let hasAPK = names.contains { URL(fileURLWithPath: $0).pathExtension.lowercased() == "apk" }
        let hasOther = names.contains { URL(fileURLWithPath: $0).pathExtension.lowercased() != "apk" }
        var lines: [String] = []
        if hasAPK, canInstall { lines.append("松开以安装") }
        if hasOther, canPush { lines.append("松开以推送到 Download") }
        return lines
    }
}

/// 文件拖到画面上时的提示层：淡强调色底、2 pt 虚线框，中间一张提示卡。
struct DropOverlay: View {
    let lines: [String]
    /// true：手机外框里的画面，虚线框跟随屏幕圆角；false：直角。
    let rounded: Bool

    var body: some View {
        ZStack {
            Theme.dropOverlay
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines, id: \.self) {
                        Text($0).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    }
                }
            }
            .floatingCard()
            .padding(16)
        }
        .overlay { border }
        .allowsHitTesting(false)
    }

    private var border: some View {
        let style = StrokeStyle(lineWidth: 2, dash: [6, 4])
        // 画面本身按同一形状裁切，向内收 1 pt 让整条虚线落在裁切范围内。
        return Group {
            if rounded {
                BezelScreenShape().stroke(Theme.accent, style: style).padding(1)
            } else {
                Rectangle().strokeBorder(Theme.accent, style: style)
            }
        }
    }
}

/// 拖放代理：悬停时按内容更新提示，没有可接收的内容时不接收；放下后交给 `onDrop`。
struct FileDropDelegate: DropDelegate {
    let canInstall: Bool
    let canPush: Bool
    @Binding var hint: [String]
    let onDrop: ([NSItemProvider]) -> Void

    private func lines(_ info: DropInfo) -> [String] {
        let names = info.itemProviders(for: [.fileURL]).map { $0.suggestedName ?? "" }
        return DropPlan.hint(forNames: names, canInstall: canInstall, canPush: canPush)
    }

    func validateDrop(info: DropInfo) -> Bool { !lines(info).isEmpty }
    func dropEntered(info: DropInfo) { hint = lines(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? { hint = lines(info); return DropProposal(operation: .copy) }
    func dropExited(info: DropInfo) { hint = [] }

    func performDrop(info: DropInfo) -> Bool {
        hint = []
        let providers = info.itemProviders(for: [.fileURL])
        guard !lines(info).isEmpty else { return false }
        onDrop(providers)
        return true
    }
}
