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

/// 设备窗口：按逻辑 id 取设备与会话，窗口出现/消失时启动/停止会话。
private struct DeviceWindowHost: View {
    let id: String
    let model: AppModel

    var body: some View {
        let state = model.sessionStates[id] ?? .idle
        let current = model.devices.first(where: { $0.id == id })
        Group {
            // 设备离开列表后沿用最后一次的信息，保留最后一帧并显示「已断开」。
            if let device = current ?? model.lastKnownDevices[id],
               let session = model.session(for: id) {
                DeviceWindowView(
                    device: device,
                    session: session,
                    state: state,
                    isPresent: current != nil,
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
        .navigationTitle((current ?? model.lastKnownDevices[id])?.name ?? id)
        .task { await model.windowOpened(id) }
        .onDisappear { Task { await model.windowClosed(id) } }
    }
}

/// 没有设备 id 的设备窗口（例如系统恢复出的空窗口）：出现即关闭。
private struct EmptyWindowCloser: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.clear.onAppear { dismiss() }
    }
}

@main
struct TandemApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            DeviceMenuView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }

        WindowGroup(id: "device", for: String.self) { $id in
            if let id {
                DeviceWindowHost(id: id, model: model)
            } else {
                EmptyWindowCloser()
            }
        }
        .commands {
            // 设备窗口只能从菜单栏按设备打开；去掉「新建窗口」(⌘N)，否则会打开没有设备的空窗口。
            CommandGroup(replacing: .newItem) {}
        }

        Window("无线配对", id: "pairing") {
            PairingView(model: model)
        }

        Settings { SettingsView(model: model) }
    }
}
