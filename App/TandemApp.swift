import SwiftUI
import DeviceCore
import AndroidDriver

/// 菜单栏图标：始终存在，因此在这里取得 openWindow，接好 AppModel 的钩子并启动 AppModel。
private struct MenuBarLabel: View {
    let model: AppModel
    let services: AppServices
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image("MenuBarIcon")
            .task {
                AppDelegate.services = services
                model.requestOpenWorkspace = {
                    NSApplication.shared.activate()
                    openWindow(id: "workspace")
                }
                model.requestOpenPopup = { openWindow(id: "device", value: $0) }
                services.connect()
                // App 宿主测试中不启动设备发现与会话，避免在手机上残留会话；钩子与同步循环照常接好。
                if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                    await model.start()
                }
                await services.clipboard.runSyncLoop { AppServices.runningSessions(of: model) }
            }
    }
}

/// 弹出窗口：按逻辑 id 取设备与会话；出现 / 消失时加入 / 移出 popped，由 AppModel 决定启停会话。
private struct DeviceWindowHost: View {
    let id: String
    let model: AppModel
    let services: AppServices

    var body: some View {
        let state = model.sessionStates[id] ?? .idle
        let current = model.devices.first(where: { $0.id == id })
        Group {
            // 设备离开列表后沿用最后一次的信息，保留最后一帧并显示「已断开」。
            if let device = current ?? model.lastKnownDevices[id],
               let session = model.session(for: id) {
                DeviceWindowView(
                    device: device,
                    services: services,
                    session: session,
                    state: state,
                    isPresent: current != nil,
                    romGuide: model.injectDenied.contains(id) ? model.romGuides[id] : nil,
                    onRetry: { Task { await model.reconnect(id) } },
                    onReconnect: { Task { await model.reconnect(id) } }
                )
            } else {
                Text("设备未连接，连接后将自动恢复")
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle((current ?? model.lastKnownDevices[id])?.name ?? id)
        .focusedSceneValue(\.captureTarget, CaptureTarget(deviceID: id, origin: .popup(id)))
        .task { await model.popupOpened(id) }
        .onDisappear { Task { await model.popupClosed(id) } }
    }
}

/// 没有设备 id 的设备窗口（例如系统恢复出的空窗口）：出现即关闭。
private struct EmptyWindowCloser: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Color.clear.onAppear { dismiss() }
    }
}

/// 菜单「设备」：截图 ⌘⇧S、开始 / 结束录屏 ⌘⇧R，作用于当前窗口的 captureTarget。
private struct CaptureCommands: Commands {
    let services: AppServices
    @FocusedValue(\.captureTarget) private var target

    var body: some Commands {
        CommandMenu("设备") {
            Button("截图") {
                guard let target else { return }
                Task { await services.commands.screenshot(target.deviceID, origin: target.origin) }
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(target.map { !services.commands.can(.screenshot, $0.deviceID) } ?? true)
            Button(target.map { services.recording.isRecording($0.deviceID) } == true ? "结束录屏" : "开始录屏") {
                guard let target else { return }
                Task { await services.commands.toggleRecording(target.deviceID, origin: target.origin) }
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .disabled(target.map { !services.commands.can(.record, $0.deviceID) } ?? true)
        }
    }
}

@main
struct TandemApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel
    /// 截图、录屏、剪贴板、操作记录等 App 级服务，只创建一次，供各窗口共用。
    @State private var services: AppServices

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        _services = State(initialValue: AppServices(model: model))
    }

    var body: some Scene {
        // 第一个场景：启动时打开工作台。
        Window("Tandem", id: "workspace") {
            WorkspaceView(model: model, services: services)
        }
        .defaultSize(width: 1200, height: 820)

        MenuBarExtra {
            DeviceMenuView(model: model)
        } label: {
            MenuBarLabel(model: model, services: services)
        }

        WindowGroup(id: "device", for: String.self) { $id in
            if let id {
                DeviceWindowHost(id: id, model: model, services: services)
            } else {
                EmptyWindowCloser()
            }
        }
        .commands {
            // 设备窗口只能从工作台弹出；去掉「新建窗口」(⌘N)，否则会打开没有设备的空窗口。
            CommandGroup(replacing: .newItem) {}
        }
        .commands { CaptureCommands(services: services) }

        Window("无线配对", id: "pairing") {
            PairingView(model: model)
        }

        Settings { SettingsView(model: model, store: services.store) }
    }
}
