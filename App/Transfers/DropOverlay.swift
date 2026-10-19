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
