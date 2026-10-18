import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Toggle("插上设备时自动打开窗口", isOn: $model.autoOpenOnConnect)
            if let adb = model.adb {
                LabeledContent("adb 路径") { Text(adb.url.path).textSelection(.enabled) }
                LabeledContent("adb 版本") { Text(adb.version) }
            } else {
                LabeledContent("adb") { Text("未找到").foregroundStyle(.secondary) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }
}
