import ControlProtocol
import DeviceCore
import AppKit
import Foundation

/// 让传输结束回调在 FilesModel 创建前就能捕获它。
@MainActor private final class FilesBox { var model: FilesModel? }

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
    let filesModel: FilesModel
    let tabs = WorkspaceTabs()
    let locks: AILocks
    let presence: AIPresence
    let ai: AICommands
    let registry: ToolRegistry
    let server: ControlServer
    /// 打开着的日志窗口的会话（按设备 id）；窗口关闭即移除。
    private(set) var logSessions: [String: LogSession] = [:]
    /// 「日志」按钮给出、尚未被窗口取走的初始目标。
    private var pendingLogTargets: [String: LogTarget] = [:]

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
        let toasts = toasts
        // onFinished 在 filesModel 创建之前构造，经此盒子转发
        let files = FilesBox()
        self.fileStore = fileStore
        transfers = TransferQueue(
            runner: runner, device: device, actions: { await model.actions(for: $0) },
            onFinished: { job in
                // 你拉取成功后在 Finder 中选中该文件（AI 的拉取不抢焦点）；其余结果只显示提示条
                if let url = Self.finderSelection(for: job) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                if let notice = TransferNotice.from(job) { toasts.show(notice, in: job.origin) }
                files.model?.transferFinished(job)
            })
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
        filesModel = FilesModel(commands: commands)
        files.model = filesModel
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
            restart: { await model.reconnect($0) },
            transfers: transfers, pullDirectory: { fileStore.pullDirectory },
            origin: { model.mirrors.popped.contains($0) ? .popup($0) : .workspace })
        let quickStore = quickStore
        registry = ToolRegistry(commands: ai, allowShell: { quickStore.allowAIShell })
        server = ControlServer(
            registry: registry, devices: { model.devices },
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
    }

    /// 「日志」按钮：记下初始目标，随后由调用方打开日志窗口。窗口已打开时保持其现有目标，只前置。
    func requestLogs(_ deviceID: String, target: LogTarget) {
        if logSessions[deviceID] == nil { pendingLogTargets[deviceID] = target }
    }

    /// 日志窗口出现时取得会话：已有则沿用，否则按待定目标（默认「全部」）新建。
    func logSession(for deviceID: String) -> LogSession {
        if let existing = logSessions[deviceID] { return existing }
        let model = model
        let session = LogSession(
            deviceID: deviceID, actions: { await model.actions(for: deviceID) },
            target: pendingLogTargets.removeValue(forKey: deviceID) ?? .all)
        logSessions[deviceID] = session
        return session
    }

    /// 日志窗口关闭：丢弃会话（run 随窗口任务取消，logcat 随之停止）。
    func releaseLogSession(_ deviceID: String, _ session: LogSession) {
        if logSessions[deviceID] === session { logSessions[deviceID] = nil }
    }

    /// 「在文件中查看」：打开工作台、选中该设备、切到「文件」标签并打开文件所在目录。
    func reveal(_ target: RevealTarget) {
        model.requestOpenWorkspace?()
        tabs.selected = .files
        Task {
            await model.select(target.deviceID)
            filesModel.reveal(deviceID: target.deviceID, path: target.path)
        }
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
        // App 宿主测试中不监听真实 socket，避免占用或删除正在运行的 Tandem 的 socket；也不清理临时目录。
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            server.start(path: ControlPaths.socketURL(home: FileManager.default.homeDirectoryForCurrentUser).path)
            let tmp = FileManager.default.temporaryDirectory
            Task.detached(priority: .utility) { Self.sweepTemporaries(in: tmp, now: Date()) }
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

    /// 传输结束后要在 Finder 中选中的文件：只有来源为「你」且成功的拉取。
    static func finderSelection(for job: TransferJob) -> URL? {
        guard job.source == .user, case .done(.pulled(let url)) = job.state else { return nil }
        return url
    }

    /// 启动时清理上次遗留的临时文件（拖到 Finder 的 tandem-drag-*、粘贴的 Tandem-paste/*），只删 24 小时前的。
    nonisolated static func sweepTemporaries(in tmp: URL, now: Date, maxAge: TimeInterval = 24 * 3600) {
        let fm = FileManager.default
        let key: Set<URLResourceKey> = [.contentModificationDateKey]
        let drags = ((try? fm.contentsOfDirectory(at: tmp, includingPropertiesForKeys: Array(key))) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("tandem-drag-") }
        let pastes = (try? fm.contentsOfDirectory(
            at: tmp.appendingPathComponent("Tandem-paste"), includingPropertiesForKeys: Array(key))) ?? []
        for url in drags + pastes {
            guard let modified = (try? url.resourceValues(forKeys: key))?.contentModificationDate,
                  now.timeIntervalSince(modified) > maxAge else { continue }
            try? fm.removeItem(at: url)
        }
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
