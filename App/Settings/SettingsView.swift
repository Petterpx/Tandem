import SwiftUI
import AppKit

struct SettingsView: View {
    @Bindable var model: AppModel
    let services: AppServices

    private var store: CaptureStore { services.store }

    private var files: FileTransferStore { services.fileStore }

    /// 选「每次询问」会清掉记住的粘贴选择；「按上次…」只在已有记住的选择时有意义。
    private var askEachPaste: Binding<Bool> {
        let files = files
        return Binding(
            get: { files.rememberedPaste == nil },
            set: { if $0 { files.rememberedPaste = nil } })
    }

    /// 经 AppServices 修改：同时让已连接的 MCP 客户端刷新工具列表。
    /// 在 body 中读取当前值，让视图观察到设置变化。
    private var allowAIShell: Binding<Bool> {
        let services = services
        let on = services.quickStore.allowAIShell
        return Binding(get: { on }, set: { services.setAllowAIShell($0) })
    }

    var body: some View {
        Form {
            Toggle("插上设备时自动显示", isOn: $model.autoOpenOnConnect)
            directoryRow("截图目录", url: store.screenshotDirectory) { store.screenshotDirectory = $0 }
            directoryRow("录屏目录", url: store.recordingDirectory) { store.recordingDirectory = $0 }
            directoryRow("拉取目录", url: files.pullDirectory) { files.pullDirectory = $0 }
            Picker("粘贴文件时", selection: askEachPaste) {
                Text("每次询问").tag(true)
                // 没有记住的选择时不可选；在粘贴确认里勾选「记住」后才会出现
                Text("按上次的选择直接推送").tag(false).disabled(files.rememberedPaste == nil)
            }
            Toggle("允许 AI 执行 shell 命令", isOn: allowAIShell)
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
