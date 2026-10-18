import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var model: AppModel
    @Bindable var store: CaptureStore

    var body: some View {
        Form {
            Toggle("插上设备时自动显示", isOn: $model.autoOpenOnConnect)
            directoryRow("截图目录", url: store.screenshotDirectory) { store.screenshotDirectory = $0 }
            directoryRow("录屏目录", url: store.recordingDirectory) { store.recordingDirectory = $0 }
            if let adb = model.adb {
                LabeledContent("adb 路径") { Text(adb.url.path).textSelection(.enabled) }
                LabeledContent("adb 版本") { Text(adb.version) }
            } else {
                LabeledContent("adb") { Text("未找到").foregroundStyle(Theme.textSecondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func directoryRow(_ title: String, url: URL, set: @escaping (URL) -> Void) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                Text((url.path as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(url.path)
                Button("选择…") {
                    if let chosen = Self.chooseDirectory(startingAt: url) { set(chosen) }
                }
            }
        }
    }

    /// 选择保存目录；目录不存在时从其上级开始浏览。
    private static func chooseDirectory(startingAt url: URL) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        var start = url
        while !FileManager.default.fileExists(atPath: start.path), start.pathComponents.count > 1 {
            start.deleteLastPathComponent()
        }
        panel.directoryURL = start
        return panel.runModal() == .OK ? panel.url : nil
    }
}
