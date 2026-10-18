import SwiftUI
import DeviceCore
import AndroidDriver

/// 菜单栏图标：始终存在，因此在这里取得 openWindow 并启动 AppModel。
private struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: "iphone.gen3")
            .task {
                AppDelegate.model = model
                model.requestOpenWindow = { openWindow(id: "device", value: $0) }
                await model.start()
            }
    }
}

/// 设备窗口：按 id 取设备与会话，窗口出现/消失时启动/停止会话。
private struct DeviceWindowHost: View {
    let id: String
    let model: AppModel

    var body: some View {
        Group {
            if let device = model.devices.first(where: { $0.id == id }),
               let session = model.session(for: id) {
                DeviceWindowView(
                    device: device,
                    session: session,
                    state: model.sessionStates[id] ?? .idle,
                    romGuide: model.injectDenied.contains(id) ? model.romGuides[id] : nil,
                    onRetry: { Task { await model.reconnect(id) } },
                    onReconnect: { Task { await model.reconnect(id) } }
                )
            } else {
                Text("设备未连接，连接后将自动恢复")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(model.devices.first(where: { $0.id == id })?.name ?? id)
        .task { await model.windowOpened(id) }
        .onDisappear { Task { await model.windowClosed(id) } }
    }
}

@main
struct MagicDevXApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            DeviceMenuView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }

        WindowGroup(id: "device", for: String.self) { $id in
            if let id { DeviceWindowHost(id: id, model: model) }
        }

        Window("无线配对", id: "pairing") {
            Text("无线配对")
        }

        Settings { SettingsView(model: model) }
    }
}
