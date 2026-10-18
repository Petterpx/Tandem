import SwiftUI
import DeviceCore

struct DeviceMenuView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let error = model.startupError {
            Text(error.message)
            if let s = error.suggestion { Text(s) }
            Divider()
        }
        Button("打开工作台") { model.requestOpenWorkspace?() }
        Divider()
        if model.devices.isEmpty {
            Text("暂无设备")
        }
        // 点设备 = 打开工作台并选中它。
        ForEach(model.devices) { device in
            Button {
                model.requestOpenWorkspace?()
                Task { await model.select(device.id) }
            } label: {
                Text(label(for: device))
            }
        }
        Divider()
        Button("无线配对…") {
            NSApplication.shared.activate()
            openWindow(id: "pairing")
        }
        SettingsLink { Text("设置…") }
        Button("退出") { NSApplication.shared.terminate(nil) }
    }

    private func label(for device: DeviceInfo) -> String {
        let kind = device.connection == .usb ? "USB" : "Wi-Fi"
        let status: String
        switch device.state {
        case .connected: status = "已连接"
        case .unauthorized: status = "未授权（请在手机上允许 USB 调试）"
        case .offline: status = "离线"
        }
        return "\(device.name) · \(kind) · \(status)"
    }
}
