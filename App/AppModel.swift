import Foundation
import Observation
import DeviceCore
import AndroidDriver

@MainActor
@Observable
final class AppModel {
    /// 合并后的设备列表；`id` 是逻辑 id（窗口、会话、状态都按它索引），adb 调用用 `serial`。
    var devices: [DeviceInfo] = []
    var sessionStates: [String: SessionState] = [:]
    var injectDenied: Set<String> = []
    var romGuides: [String: RomGuide] = [:]
    var adb: Adb?
    private(set) var wirelessConnector: WirelessConnector?
    var startupError: DeviceError?
    var openWindowIDs: Set<String> = []
    /// 已创建会话的设备 id（被观察，让窗口在会话就绪后刷新）。
    private(set) var sessionIDs: Set<String> = []
    var autoOpenOnConnect: Bool {
        didSet { defaults.set(autoOpenOnConnect, forKey: Self.autoOpenKey) }
    }
    /// 由 SwiftUI 注入 openWindow。
    @ObservationIgnored var requestOpenWindow: ((String) -> Void)?

    static let autoOpenKey = "autoOpenOnConnect"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var manager: DeviceManager?
    @ObservationIgnored private var adbClient: AdbClient?
    @ObservationIgnored private var sessions: [String: any DeviceSession] = [:]
    @ObservationIgnored private var eventTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var deviceTask: Task<Void, Never>?
    @ObservationIgnored private var autoOpened = Set<String>()
    @ObservationIgnored private var started = false
    @ObservationIgnored private var terminating = false
    @ObservationIgnored private var restarting = Set<String>()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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
                                       suggestion: "请重新安装 MagicDevX")
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

    func windowOpened(_ id: String) async {
        guard !terminating else { return }
        openWindowIDs.insert(id)
        guard let session = await ensureSession(id), canRun(id) else { return }
        await session.start()
    }

    func windowClosed(_ id: String) async {
        openWindowIDs.remove(id)
        injectDenied.remove(id)
        romGuides[id] = nil
        await sessions[id]?.stop()
    }

    /// 「已打开，重新连接」：stop 后 start，并清除横幅。
    func reconnect(_ id: String) async {
        injectDenied.remove(id)
        romGuides[id] = nil
        await restart(id)
    }

    /// 停止所有会话（App 退出时调用）。
    func stopAll() async {
        terminating = true
        let all = Array(sessions.values)
        await withTaskGroup(of: Void.self) { group in
            for session in all { group.addTask { await session.stop() } }
        }
    }

    // MARK: - 内部

    private func devicesUpdated(_ list: [DeviceInfo]) async {
        devices = list
        guard !terminating else { return }
        for id in AppPolicy.autoOpenIDs(devices: list, seen: &autoOpened, enabled: autoOpenOnConnect) {
            requestOpenWindow?(id)
        }
        // 首选传输变了：在新传输上重启（DeviceManager 已把新的 serial 推给会话）。
        var activeSerials: [String: String] = [:]
        for (id, session) in sessions { activeSerials[id] = session.activeSerial }
        for id in AppPolicy.handoverIDs(devices: list, openWindowIDs: openWindowIDs, activeSerials: activeSerials) {
            Task { await restart(id) }
        }
        let ids = AppPolicy.reconnectIDs(devices: list, openWindowIDs: openWindowIDs, states: sessionStates)
        for id in ids {
            guard let session = await ensureSession(id), canRun(id) else { continue }
            Task { await session.start() }
        }
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

    /// 任何 await 之后、启动会话之前都要重新确认：窗口仍开着且 App 没在退出。
    private func canRun(_ id: String) -> Bool {
        !terminating && openWindowIDs.contains(id)
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
