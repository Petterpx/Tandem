import SwiftUI
import DeviceCore

struct DeviceMenuView: View {
    let model: AppModel
    let services: AppServices
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let error = model.startupError {
            Text(error.message)
            if let s = error.suggestion { Text(s) }
            Divider()
        }
        // AI 状态行（不可点）
        Text(aiStatus)
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
        let locked = services.locks.isLocked(device.id) ? " · 禁止 AI" : ""
        return "\(device.name) · \(kind) · \(status)\(locked)"
    }

    private var aiStatus: String {
        if case .failed = services.server.status { return "AI：服务未启动" }
        let count = services.server.clients.count
        return count > 0 ? "AI：已连接 \(count) 个客户端" : "AI：未连接"
    }
}
