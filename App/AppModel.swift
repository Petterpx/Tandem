import Foundation
import Observation
import DeviceCore
import AndroidDriver

/// 会话结束的原因（录屏自动结束、剪贴板同步等据此收尾）。
enum SessionEndReason: Equatable {
    /// 设备断开或会话失败
    case disconnected
    /// 不再需要运行：停止投屏、移除、关闭工作台 / 弹出窗口
    case stopped
    /// App 退出
    case quit
}

@MainActor
@Observable
final class AppModel {
    /// 合并后的设备列表；`id` 是逻辑 id（窗口、会话、状态都按它索引），adb 调用用 `serial`。
    var devices: [DeviceInfo] = []
    /// 每个逻辑 id 最近一次出现在列表里的信息：设备离开列表后仍用它显示「已断开」。
    private(set) var lastKnownDevices: [String: DeviceInfo] = [:]
    var sessionStates: [String: SessionState] = [:]
    var injectDenied: Set<String> = []
    var romGuides: [String: RomGuide] = [:]
    /// 用户已关闭横幅的设备；只对本次投屏会话有效（reconnect / sessionLeft 时清除）。
    private(set) var romBannerDismissed: Set<String> = []
    var adb: Adb?
    private(set) var wirelessConnector: WirelessConnector?
    var startupError: DeviceError?
    /// 需要运行会话的设备集合；每次修改都经 `updateMirrors` 启动 / 停止会话。
    private(set) var mirrors = MirrorSet()
    /// 工作台中当前选中的设备。
    var selectedID: String?
    /// 「移除」过、尚未再次连接的设备：即使 adb 仍列出（如断网的 Wi-Fi 设备为 offline）也不在左栏显示。
    private(set) var removedIDs: Set<String> = []
    /// 已创建会话的设备 id（被观察，让窗口在会话就绪后刷新）。
    private(set) var sessionIDs: Set<String> = []
    var autoOpenOnConnect: Bool {
        didSet { defaults.set(autoOpenOnConnect, forKey: Self.autoOpenKey) }
    }
    /// 由 SwiftUI 注入：打开工作台窗口。
    @ObservationIgnored var requestOpenWorkspace: (() -> Void)?
    /// 由 SwiftUI 注入：按逻辑 id 打开弹出窗口。
    @ObservationIgnored var requestOpenPopup: ((String) -> Void)?
    /// 会话结束时调用（在 stop 之前）；退出时对每个会话调用一次 `.quit`。
    @ObservationIgnored var onSessionEnded: ((String, SessionEndReason) -> Void)?
    /// 设备剪贴板变化：(逻辑 id, 文本)。
    @ObservationIgnored var onDeviceClipboard: ((String, String) -> Void)?

    static let autoOpenKey = "autoOpenOnConnect"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var manager: DeviceManager?
    @ObservationIgnored private var adbClient: AdbClient?
    @ObservationIgnored private var sessions: [String: any DeviceSession] = [:]
    @ObservationIgnored private var eventTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var deviceTask: Task<Void, Never>?
    @ObservationIgnored private var autoOpened = Set<String>()
    /// 已按其启动 / 停止过会话的 wanted；与当前 `mirrors.wanted` 的差异就是待处理的变化。
    @ObservationIgnored private var appliedWanted = Set<String>()
    @ObservationIgnored private var started = false
    /// 设备列表写入 `devices` 之后调用（MCP 桥据此更新设备视图）。
    @ObservationIgnored var onDevicesChanged: (([DeviceInfo]) -> Void)?
    @ObservationIgnored private var terminating = false
    @ObservationIgnored private var restarting = Set<String>()
    /// 自上次 running 以来连续断开 / 失败的次数（自动重连退避用）。
    @ObservationIgnored private var failureCounts: [String: Int] = [:]
    @ObservationIgnored private var retryTasks: [String: Task<Void, Never>] = [:]

    /// 以 `--background` 拉起、用户还没打开过工作台：不自动打开工作台。
    @ObservationIgnored private(set) var backgroundLaunch: Bool

    init(defaults: UserDefaults = .standard, backgroundLaunch: Bool = false) {
        self.defaults = defaults
        self.backgroundLaunch = backgroundLaunch
        self.autoOpenOnConnect = defaults.bool(forKey: Self.autoOpenKey)
    }

    func start() async {
        guard !started else { return }
        started = true
        let runner = SystemProcessRunner()
        let locator = AdbLocator(
            runner: runner,
            environment: ProcessInfo.processInfo.environment,
            home: FileManager.default.homeDirectoryForCurrentUser,
            bundled: Self.vendorURL("adb")
        )
        let located: Adb
        do { located = try await locator.locate() }
        catch let error as DeviceError { startupError = error; return }
        catch { startupError = .adbNotFound(); return }
        guard let jar = Self.vendorURL("scrcpy-server-v5.0.1") else {
            startupError = DeviceError(code: .CONNECTION_FAILED, message: "缺少内置的 scrcpy-server",
                                       suggestion: "请重新安装 Tandem")
            return
        }
        adb = located
        let client = AdbClient(adb: located, runner: runner)
        adbClient = client
        wirelessConnector = WirelessConnector(adb: client)
        let driver = AndroidDriver(adb: client, runner: runner, serverJar: jar)
        let manager = DeviceManager(drivers: [driver])
        self.manager = manager
        let stream = await manager.devices()
        deviceTask = Task { [weak self] in
            for await list in stream {
                await self?.devicesUpdated(list)
            }
        }
    }

    func session(for id: String) -> (any DeviceSession)? {
        sessionIDs.contains(id) ? sessions[id] : nil
    }

    /// 按逻辑 id 取设备操作（每次按当前传输新建；设备不在或未连接时为 nil）。
    func actions(for id: String) async -> (any DeviceActions)? {
        await manager?.actions(for: id)
    }

    /// 左栏设备列表：当前设备列表，加上保持中（kept）但已离开列表的设备（显示为离线），去掉已移除的设备。
    var sidebarDevices: [DeviceInfo] {
        AppPolicy.sidebarDevices(devices: devices, lastKnown: lastKnownDevices, kept: mirrors.kept, removed: removedIDs)
    }

    // MARK: - 会话规则（spec §3）

    /// 工作台中选中设备：选中过就保持运行。
    func select(_ id: String) async {
        selectedID = id
        await updateMirrors { $0.select(id) }
    }

    /// 右键「停止投屏」：未弹出则停止会话，再次选中时重新启动。
    func stopMirroring(_ id: String) async {
        await updateMirrors { $0.stopMirroring(id) }
    }

    /// 右键「移除」：停止会话并从列表删除；设备再次连接时重新出现。
    func remove(_ id: String) async {
        if selectedID == id { selectedID = nil }
        lastKnownDevices[id] = nil
        removedIDs.insert(id)
        await updateMirrors { $0.remove(id) }
    }

    /// 弹出为独立窗口：已在运行则不重启。窗口出现后由 `popupOpened` 确认。
    func popOut(_ id: String) {
        guard !terminating else { return }
        mirrors.popOut(id)
        requestOpenPopup?(id)
        Task { await self.applyWanted() }
    }

    /// 弹出窗口出现（包括系统恢复出的窗口，此前没有调用 popOut）。
    func popupOpened(_ id: String) async {
        await updateMirrors { $0.popOut(id) }
    }

    /// AI（MCP）开始使用设备：加入 ai 集合并按需启动会话。
    func aiAcquire(_ id: String) async {
        await updateMirrors { $0.aiAcquire(id) }
    }

    func aiRelease(_ id: String) async {
        await updateMirrors { $0.aiRelease(id) }
    }

    func popupClosed(_ id: String) async {
        await updateMirrors { $0.popupClosed(id) }
    }

    /// 工作台出现：恢复所有保持中的会话。
    func workspaceAppeared() async {
        await updateMirrors { $0.setWorkspaceOpen(true) }
    }

    /// 工作台关闭：停止所有未弹出设备的会话，kept 保留。
    func workspaceDisappeared() async {
        await updateMirrors { $0.setWorkspaceOpen(false) }
    }

    /// 用户亲自打开工作台（菜单、Dock、点设备）：之后恢复插上自动显示。
    func endBackgroundLaunch() {
        backgroundLaunch = false
    }

    func dismissRomBanner(_ id: String) {
        romBannerDismissed.insert(id)
    }

    /// 该设备当前应显示的 ROM 横幅；注入被拒且未被关闭时才有。
    func romBanner(for id: String) -> RomGuide? {
        guard injectDenied.contains(id), !romBannerDismissed.contains(id) else { return nil }
        return romGuides[id]
    }

    /// 「重试」/「已打开，重新连接」：stop 后 start，清除横幅并重置自动重连次数。
    func reconnect(_ id: String) async {
        resetRetry(id)
        injectDenied.remove(id)
        romBannerDismissed.remove(id)
        romGuides[id] = nil
        await restart(id)
    }

    /// 停止所有会话（App 退出时调用）。
    func stopAll() async {
        terminating = true
        for id in sessions.keys { onSessionEnded?(id, .quit) }
        retryTasks.values.forEach { $0.cancel() }
        retryTasks.removeAll()
        let all = Array(sessions.values)
        await withTaskGroup(of: Void.self) { group in
            for session in all { group.addTask { await session.stop() } }
        }
    }

    // MARK: - 内部

    /// 设备列表更新（DeviceManager 推送；测试中直接调用）。
    func devicesUpdated(_ list: [DeviceInfo]) async {
        let previous = Dictionary(devices.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        devices = list
        onDevicesChanged?(list)
        for device in list { lastKnownDevices[device.id] = device }
        // 被移除的设备再次连接：回到左栏。
        let stillRemoved = AppPolicy.stillRemoved(removedIDs, previous: previous, devices: list)
        if stillRemoved != removedIDs { removedIDs = stillRemoved }
        guard !terminating else { return }
        // 设备回来（变为 connected）：重新获得完整的自动重连次数。
        for device in list where AppPolicy.shouldResetRetries(previous: previous[device.id], current: device.state) {
            resetRetry(device.id)
        }
        // 首选传输变了：在新传输上重启（DeviceManager 已把新的 serial 推给会话）。
        var activeSerials: [String: String] = [:]
        for (id, session) in sessions { activeSerials[id] = session.activeSerial }
        for id in AppPolicy.handoverIDs(devices: list, wanted: mirrors.wanted, activeSerials: activeSerials) {
            Task { await restart(id) }
        }
        let ids = AppPolicy.reconnectIDs(devices: list, wanted: mirrors.wanted, states: sessionStates)
        for id in ids {
            guard let session = await ensureSession(id), canRun(id) else { continue }
            Task {
                // 排队期间可能已停止投屏 / 关闭工作台，启动前再确认一次。
                guard canRun(id) else { return }
                await session.start()
            }
        }
        // 插上自动显示：打开工作台并选中新设备（放在重连之后，避免同一会话被重复启动）。
        // 后台拉起期间 seen 照常记录，启动时就在的设备之后也不会补开。
        let autoOpen = AppPolicy.autoOpenEnabled(setting: autoOpenOnConnect, backgroundLaunch: backgroundLaunch)
        for id in AppPolicy.autoOpenIDs(devices: list, seen: &autoOpened, enabled: autoOpen) {
            requestOpenWorkspace?()
            Task { await select(id) }
        }
    }

    /// 修改 mirrors，并按新旧 wanted 的差异启动 / 停止会话。
    private func updateMirrors(_ change: (inout MirrorSet) -> Void) async {
        guard !terminating else { return }
        change(&mirrors)
        await applyWanted()
    }

    /// 比较当前 wanted 与上次处理过的 wanted：离开的先 `onSessionEnded(.stopped)` 再 stop，新加入的创建会话并 start。
    /// 差异在第一个 await 之前就记下，并发调用不会重复处理同一个 id。
    private func applyWanted() async {
        guard !terminating else { return }
        let now = mirrors.wanted
        let leaving = appliedWanted.subtracting(now)
        let joining = now.subtracting(appliedWanted)
        appliedWanted = now
        guard !leaving.isEmpty || !joining.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for id in leaving { group.addTask { await self.sessionLeft(id) } }
            for id in joining { group.addTask { await self.sessionJoined(id) } }
        }
    }

    private func sessionJoined(_ id: String) async {
        resetRetry(id)
        guard let session = await ensureSession(id), canRun(id) else { return }
        await session.start()
    }

    private func sessionLeft(_ id: String) async {
        onSessionEnded?(id, .stopped)
        resetRetry(id)
        injectDenied.remove(id)
        romBannerDismissed.remove(id)
        romGuides[id] = nil
        await sessions[id]?.stop()
    }

    /// stop 后 start；同一 id 同时只有一次重启在进行。
    private func restart(_ id: String) async {
        guard canRun(id), !restarting.contains(id), let session = sessions[id] else { return }
        restarting.insert(id)
        defer { restarting.remove(id) }
        await session.stop()
        guard canRun(id) else { return }
        await session.start()
    }

    // MARK: 自动重连

    private func scheduleRetry(_ id: String, after state: SessionState) {
        let device = devices.first { $0.id == id }
        guard !terminating, retryTasks[id] == nil,
              AppPolicy.shouldAutoRetry(state: state, wanted: mirrors.wanted.contains(id), device: device) else { return }
        let failures = (failureCounts[id] ?? 0) + 1
        failureCounts[id] = failures
        guard let delay = AppPolicy.retryDelay(afterFailures: failures) else {
            // 放弃自动重连：断开也显示成失败，让界面出现「重试」。
            if case .disconnected = state {
                sessionStates[id] = .failed(DeviceError(code: .CONNECTION_FAILED, message: "连接已断开，自动重连未成功",
                                                        suggestion: "请检查设备后点击重试"))
            }
            return
        }
        retryTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            await self?.retryNow(id)
        }
    }

    private func retryNow(_ id: String) async {
        retryTasks[id] = nil
        // 等待期间可能已不再需要运行、App 可能在退出、设备可能已离线，或者别处已经重新启动了会话。
        guard canRun(id), devices.first(where: { $0.id == id })?.state == .connected,
              let session = sessions[id] else { return }
        switch sessionStates[id] ?? .idle {
        case .disconnected, .failed, .idle: await session.start()
        case .connecting, .running: return
        }
    }

    private func resetRetry(_ id: String) {
        failureCounts[id] = nil
        retryTasks.removeValue(forKey: id)?.cancel()
    }

    /// 任何 await 之后、启动会话之前都要重新确认：仍在 wanted 中且 App 没在退出。
    private func canRun(_ id: String) -> Bool {
        !terminating && mirrors.wanted.contains(id)
    }

    private func ensureSession(_ id: String) async -> (any DeviceSession)? {
        if let existing = sessions[id] { return existing }
        guard let session = await manager?.session(for: id) else { return nil }
        if let existing = sessions[id] { return existing }  // 等待期间已被创建
        sessions[id] = session
        sessionIDs.insert(id)
        let events = session.events
        eventTasks[id] = Task { [weak self] in
            for await event in events {
                await self?.handle(event, id: id)
            }
        }
        return session
    }

    private func handle(_ event: SessionEvent, id: String) async {
        switch event {
        case .state(let state):
            sessionStates[id] = state
            switch state {
            case .running: resetRetry(id)
            case .disconnected, .failed:
                onSessionEnded?(id, .disconnected)
                scheduleRetry(id, after: state)
            case .idle, .connecting: break
            }
        case .clipboardChanged(let text):
            onDeviceClipboard?(id, text)
        case .injectPermissionDenied:
            injectDenied.insert(id)
            var manufacturer = ""
            // id 是逻辑 id，adb 要用当前传输的 serial。
            if let client = adbClient,
               let serial = sessions[id]?.activeSerial ?? devices.first(where: { $0.id == id })?.serial {
                manufacturer = (try? await client.getprop(serial, "ro.product.manufacturer")) ?? ""
            }
            guard injectDenied.contains(id) else { return }
            romGuides[id] = RomGuide.forManufacturer(manufacturer)
        }
    }

    private static func vendorURL(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Vendor")
    }
}
