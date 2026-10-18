import ControlProtocol
import DeviceCore
import Foundation

/// App 级服务：只创建一次，共用同一个 MacPasteboard（剪贴板同步据此识别 App 自己的写入）。
@MainActor
final class AppServices {
    let model: AppModel
    let pasteboard: MacPasteboard
    let store: CaptureStore
    let log: ActivityLog
    let runner: ActionRunner
    let toasts: ToastCenter
    let recording: RecordingService
    let clipboard: ClipboardService
    let fileStore: FileTransferStore
    let transfers: TransferQueue
    let commands: DeviceCommands
    let quickStore: QuickActionsStore
    let quickModel: QuickActionsModel
    let locks: AILocks
    let presence: AIPresence
    let ai: AICommands
    let registry: ToolRegistry
    let server: ControlServer

    /// App 包内的 tandem-mcp（Contents/MacOS/tandem-mcp）；未构建进包时为 nil。
    static var mcpExecutablePath: String? { Bundle.main.url(forAuxiliaryExecutable: "tandem-mcp")?.path }

    init(model: AppModel, pasteboard: MacPasteboard = MacPasteboard(), defaults: UserDefaults = .standard) {
        self.model = model
        self.pasteboard = pasteboard
        store = CaptureStore(pasteboard: pasteboard, defaults: defaults)
        log = ActivityLog()
        runner = ActionRunner(log: log)
        toasts = ToastCenter()
        recording = RecordingService(store: store)
        clipboard = ClipboardService(pasteboard: pasteboard, defaults: defaults)
        // 设备离开列表后沿用最后一次的信息，录屏收尾与记录仍有设备名
        let device: (String) -> DeviceInfo? = { id in model.devices.first { $0.id == id } ?? model.lastKnownDevices[id] }
        let fileStore = FileTransferStore(defaults: defaults)
        self.fileStore = fileStore
        transfers = TransferQueue(
            runner: runner, device: device, actions: { await model.actions(for: $0) }, onFinished: { _ in })
        commands = DeviceCommands(
            runner: runner, store: store, recording: recording, clipboard: clipboard, toasts: toasts,
            transfers: transfers, device: device,
            // 只有 running 的会话才可用：停止 / 失败后的会话对象仍留在模型里，但不会再产生画面。
            session: { Self.runningOnly(model.sessionStates[$0], model.session(for: $0)) },
            actions: { await model.actions(for: $0) },
            isPopupOpen: { model.mirrors.popped.contains($0) },
            pullDirectory: { fileStore.pullDirectory })
        quickStore = QuickActionsStore(defaults: defaults)
        quickModel = QuickActionsModel(commands: commands, store: quickStore)
        locks = AILocks(defaults: defaults)
        presence = AIPresence()
        ai = AICommands(
            runner: runner, clipboard: clipboard, presence: presence, locks: locks,
            devices: { model.devices },
            session: { Self.runningOnly(model.sessionStates[$0], model.session(for: $0)) },
            sessionState: { model.sessionStates[$0] },
            actions: { await model.actions(for: $0) },
            acquire: { await model.aiAcquire($0) },
            isWanted: { model.mirrors.wanted.contains($0) },
            restart: { await model.reconnect($0) })
        let quickStore = quickStore
        registry = ToolRegistry(commands: ai, allowShell: { quickStore.allowAIShell })
        server = ControlServer(
            registry: registry, devices: { model.devices },
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
    }

    /// 把 AppModel 的会话结束、设备剪贴板与设备列表事件接到服务上，并启动控制服务。
    func connect() {
        let model = model
        let commands = commands
        let clipboard = clipboard
        let server = server
        let transfers = transfers
        model.onSessionEnded = { id, reason in
            // 退出时由 shutdown 统一收尾并等待；这里不再起一个没人等待的收尾任务。
            guard reason != .quit else { return }
            Task { await commands.sessionEnded(id, reason: reason) }
        }
        model.onDeviceClipboard = { clipboard.deviceClipboardChanged($0, text: $1) }
        model.onDevicesChanged = { list in
            server.devicesChanged(list)
            // 有传输的设备离开列表或不再是 connected：当前项失败、其余项取消
            let connected = Set(list.filter { $0.state == .connected }.map(\.id))
            for id in transfers.busyDeviceIDs where !connected.contains(id) { transfers.deviceDisconnected(id) }
        }
        // App 宿主测试中不监听真实 socket，避免占用或删除正在运行的 Tandem 的 socket。
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            server.start(path: ControlPaths.socketURL(home: FileManager.default.homeDirectoryForCurrentUser).path)
        }
    }

    /// 「禁止 AI 操作」开关：写一条来源为「你」的记录；打开时同时把设备移出 AI 使用（不再被需要的会话随之停止）。
    func setAILocked(_ id: String, _ on: Bool) async {
        locks.setLocked(id, on)
        if let device = model.devices.first(where: { $0.id == id }) ?? model.lastKnownDevices[id] {
            runner.note(on ? "禁止 AI 操作" : "允许 AI 操作", device: device, source: .user)
        }
        if on { await model.aiRelease(id) }
    }

    /// 「允许 AI 执行 shell 命令」开关：保存设置，并让已连接的 MCP 客户端刷新工具列表。
    func setAllowAIShell(_ on: Bool) {
        quickStore.allowAIShell = on
        server.toolsChanged()
    }

    /// AI 空闲释放：定期把 5 分钟没有调用的设备移出 MirrorSet.ai（不再被其他入口需要的会话随之停止）。
    func runAIIdleLoop(interval: Duration = .seconds(30)) async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: interval) } catch { return }
            let expired = AppPolicy.expiredAIIDs(ai: model.mirrors.ai, lastUsed: presence.lastUsed, now: Date())
            for id in expired { await model.aiRelease(id) }
        }
    }

    /// 退出 App：录屏收尾与停止会话并发进行，两者都完成后返回（期限由调用方控制）。
    /// 停止会话放进子任务（要等主线程空出来才开始）；录屏收尾在这里直接调用，第一次挂起前就同步摘除所有录屏，
    /// 所以停会话引起的断开事件不会再抢到录屏。
    func shutdown() async {
        // 先关闭控制服务：不再接受新的 AI 调用，tandem-mcp 那边进行中的调用返回 APP_UNAVAILABLE
        server.stop()
        let model = model
        async let sessions: Void = model.stopAll()
        await commands.stopAllRecordings()
        await sessions
    }

    /// 状态为 running 才返回会话，否则 nil（录屏 / 剪贴板等所有入口共用）。
    static func runningOnly(_ state: SessionState?, _ session: (any DeviceSession)?) -> (any DeviceSession)? {
        if case .running = state { return session }
        return nil
    }

    /// 剪贴板同步循环使用的会话：只取状态为 running 的设备。
    static func runningSessions(of model: AppModel) -> [String: any DeviceSession] {
        var result: [String: any DeviceSession] = [:]
        for (id, state) in model.sessionStates {
            guard case .running = state, let session = model.session(for: id) else { continue }
            result[id] = session
        }
        return result
    }
}
