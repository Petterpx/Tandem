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

    /// 悬停时的提示文案：拿不到拖入内容，按设备能力给出可接收的操作。
    static func hint(canInstall: Bool, canPush: Bool) -> [String] {
        var lines: [String] = []
        if canInstall { lines.append("松开以安装") }
        if canPush { lines.append("松开以推送到 Download") }
        return lines
    }
}

/// 文件拖到画面上时的提示层。
struct DropOverlay: View {
    let lines: [String]

    var body: some View {
        ZStack {
            Theme.dropOverlay
            VStack(spacing: 6) {
                ForEach(lines, id: \.self) { Text($0).font(.headline).foregroundStyle(Theme.onVideo) }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.accent, lineWidth: 3))
        .allowsHitTesting(false)
    }
}
