import AppKit
import DeviceCore
import Foundation
import Testing
@testable import Tandem

/// 一次性闸门：wait 挂起直到 open。
private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
@Suite struct QuickActionsModelTests {
    private struct Env {
        let model: QuickActionsModel
        let store: QuickActionsStore
        let log: ActivityLog
    }

    private static let all: Set<Capability> = [.network, .apps, .openURL, .devOptions, .systemSettings, .shell]

    private func device(_ id: String, _ capabilities: Set<Capability> = all) -> DeviceInfo {
        DeviceInfo(
            serial: "s-\(id)", platform: .android, name: id, state: .connected, connection: .usb,
            hardwareSerial: id, capabilities: capabilities)
    }

    private func make(_ devices: [(DeviceInfo, RecordingActions)]) -> Env {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let mac = MacPasteboard(NSPasteboard(name: .init(UUID().uuidString)))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let captures = CaptureStore(pasteboard: mac, defaults: defaults, home: home)
        let log = ActivityLog()
        let infos = Dictionary(uniqueKeysWithValues: devices.map { ($0.0.id, $0.0) })
        let actions = Dictionary(uniqueKeysWithValues: devices.map { ($0.0.id, $0.1) })
        let commands = DeviceCommands(
            runner: ActionRunner(log: log), store: captures, recording: RecordingService(store: captures),
            clipboard: ClipboardService(pasteboard: mac, defaults: defaults), toasts: ToastCenter(),
            device: { infos[$0] }, session: { _ in nil },
            actions: { actions[$0] }, isPopupOpen: { _ in false })
        let store = QuickActionsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return Env(model: QuickActionsModel(commands: commands, store: store), store: store, log: log)
    }

    @Test func targetPackageFollowsSelection() async {
        let actions = RecordingActions()
        let dev = device("A")
        let e = make([(dev, actions)])
        #expect(e.model.targetPackage(dev.id) == nil)

        await e.model.refresh(dev.id, section: .apps)
        #expect(e.model.targetPackage(dev.id) == "com.demo")

        e.store.pin("com.other")
        await e.model.setTarget(dev.id, .pinned("com.other"))
        #expect(e.model.targetPackage(dev.id) == "com.other")

        // 移除固定后回到「前台 App」
        e.model.unpin("com.other")
        #expect(e.model.currentTarget(dev.id) == .foreground)
        #expect(e.model.targetPackage(dev.id) == "com.demo")

        // 前台 App 读不到：不能沿用上一次的包名
        actions.errors["foregroundApp"] = DeviceError(code: .CONNECTION_FAILED, message: "无法识别前台 App")
        await e.model.refresh(dev.id, section: .apps)
        #expect(e.model.targetPackage(dev.id) == nil)

        // 固定的目标不依赖前台 App
        e.store.pin("com.pinned")
        await e.model.setTarget(dev.id, .pinned("com.pinned"))
        #expect(e.model.targetPackage(dev.id) == "com.pinned")
    }

    @Test func staleResultDoesNotOverwriteOtherDevice() async {
        let gate = Gate()
        let a = RecordingActions()
        a.networkStateResult = NetworkState(wifi: false, data: false, airplane: true)
        a.networkStateHook = { await gate.wait() }
        let b = RecordingActions()
        b.networkStateResult = NetworkState(wifi: true, data: true, airplane: false)
        let devA = device("A"), devB = device("B")
        let e = make([(devA, a), (devB, b)])

        let pending = Task { await e.model.refresh(devA.id, section: .network) }
        // 等 A 的读取真正开始并挂起
        for _ in 0..<1000 where !a.calls.contains("networkState") { await Task.yield() }
        #expect(a.calls == ["networkState"])

        // 切换到 B 并刷新
        await e.model.refresh(devB.id, section: .network)
        #expect(e.model.network[devB.id] == .success(b.networkStateResult))
        #expect(e.model.network[devA.id] == nil)

        // A 晚返回：只写入 A
        await gate.open()
        await pending.value
        #expect(e.model.network[devA.id] == .success(a.networkStateResult))
        #expect(e.model.network[devB.id] == .success(b.networkStateResult))
    }

    @Test func refreshAllReadsEachSupportedSection() async {
        let full = RecordingActions()
        let partial = RecordingActions()
        let none = RecordingActions()
        let devFull = device("F")
        let devPartial = device("P", [.network, .apps, .systemSettings])
        let devNone = device("N", [])
        let e = make([(devFull, full), (devPartial, partial), (devNone, none)])

        await e.model.refreshAll(devFull.id)
        // 系统分段在前台 App 之后读取，App 语言取当前目标
        #expect(Set(full.calls) == ["networkState", "foregroundApp", "devOptions", "systemSettings com.demo"])
        #expect(full.calls.count == 4)
        #expect(e.model.devOptions[devFull.id] != nil)

        await e.model.refreshAll(devPartial.id)
        #expect(Set(partial.calls) == ["networkState", "foregroundApp", "systemSettings com.demo"])
        #expect(partial.calls.count == 3)
        #expect(e.model.devOptions[devPartial.id] == nil)

        await e.model.refreshAll(devNone.id)
        #expect(none.calls.isEmpty)
        #expect(e.model.network[devNone.id] == nil)
        #expect(e.log.entries.isEmpty)
    }

    @Test func failedNetworkSetRereadsActualState() async {
        let actions = RecordingActions()
        actions.errors["setNetwork"] = DeviceError(code: .CONNECTION_FAILED, message: "设置未生效")
        let dev = device("A")
        let e = make([(dev, actions)])

        await e.model.setNetwork(dev.id, .wifi, on: false)
        #expect(actions.calls == ["setNetwork wifi false", "networkState"])
        #expect(e.model.network[dev.id] == .success(actions.networkStateResult))
        #expect(!e.model.isBusy(dev.id, .network))
        #expect(e.log.entries.first?.failure == "设置未生效")

        // 成功时直接用回读值，不再额外读取
        actions.errors = [:]
        await e.model.setNetwork(dev.id, .data, on: false)
        #expect(actions.calls.suffix(1) == ["setNetwork data false"])
        #expect((try? e.model.network[dev.id]?.get())?.data == false)
    }

    @Test func appActionsRereadForegroundExceptClearData() async {
        let actions = RecordingActions()
        let dev = device("A", [.apps])
        let e = make([(dev, actions)])

        await e.model.appAction(dev.id, .clearData, package: "com.demo")
        #expect(actions.calls == ["clearData com.demo"])

        await e.model.appAction(dev.id, .launch, package: "com.demo")
        #expect(actions.calls.suffix(2) == ["launchApp com.demo", "foregroundApp"])
        #expect(e.model.targetPackage(dev.id) == "com.demo")
        #expect(!e.model.isBusy(dev.id, .apps))
    }
}
