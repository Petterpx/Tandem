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
        await e.model.unpin("com.other")
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

    @Test func targetPackageChangeRereadsSystem() async {
        let actions = RecordingActions()
        let dev = device("A")
        let e = make([(dev, actions)])
        await e.model.refreshAll(dev.id)
        #expect(actions.calls.contains("systemSettings com.demo"))
        #expect(e.model.systemMatchesTarget(dev.id))

        // 刷新「应用」后前台 App 变了：按新包名重读系统
        actions.foregroundAppResult = AppInfo(package: "com.next")
        await e.model.refresh(dev.id, section: .apps)
        #expect(actions.calls.suffix(2) == ["foregroundApp", "systemSettings com.next"])
        #expect(e.model.systemMatchesTarget(dev.id))

        // 包名没变：不重读
        await e.model.refresh(dev.id, section: .apps)
        #expect(actions.calls.suffix(1) == ["foregroundApp"])

        // 改选固定的目标
        e.store.pin("com.p")
        await e.model.setTarget(dev.id, .pinned("com.p"))
        #expect(actions.calls.suffix(1) == ["systemSettings com.p"])

        // 目标是固定包名时，前台 App 变化不触发重读
        actions.foregroundAppResult = AppInfo(package: "com.third")
        await e.model.refresh(dev.id, section: .apps)
        #expect(actions.calls.suffix(1) == ["foregroundApp"])

        // 移除固定：目标回到前台 App，按前台包名重读
        await e.model.unpin("com.p")
        #expect(e.model.currentTarget(dev.id) == .foreground)
        #expect(actions.calls.suffix(1) == ["systemSettings com.third"])
        #expect(e.model.systemMatchesTarget(dev.id))
    }

    @Test func foregroundReadInFlightHidesTargetPackage() async {
        let gate = Gate()
        let actions = RecordingActions()
        let dev = device("A")
        let e = make([(dev, actions)])
        await e.model.refreshAll(dev.id)
        #expect(e.model.targetPackage(dev.id) == "com.demo")

        actions.foregroundAppHook = { await gate.wait() }
        let pending = Task { await e.model.refresh(dev.id, section: .apps) }
        for _ in 0..<1000 where actions.calls.filter({ $0 == "foregroundApp" }).count < 2 { await Task.yield() }
        // 读取进行中：上一次的包名不可用，App 语言也不显示
        #expect(e.model.isReadingForeground(dev.id))
        #expect(e.model.targetPackage(dev.id) == nil)
        #expect(!e.model.systemMatchesTarget(dev.id))

        await gate.open()
        await pending.value
        #expect(!e.model.isReadingForeground(dev.id))
        #expect(e.model.targetPackage(dev.id) == "com.demo")
        #expect(e.model.systemMatchesTarget(dev.id))
        // 包名没变，不重读系统
        #expect(actions.calls.filter { $0.hasPrefix("systemSettings") }.count == 1)
    }

    @Test func devAndSystemChangesRereadSection() async {
        let actions = RecordingActions()
        let dev = device("A")
        let e = make([(dev, actions)])
        await e.model.refreshAll(dev.id)

        actions.devOptionsResult = DevOptions(showTouches: true)
        await e.model.setDevOption(dev.id, .showTouches(true))
        #expect(actions.calls.suffix(2) == ["setDevOption showTouches(true)", "devOptions"])
        #expect((try? e.model.devOptions[dev.id]?.get())?.showTouches == true)
        #expect(e.log.entries.first?.title == "显示触摸点：开")
        #expect(!e.model.isBusy(dev.id, .devOptions))

        // 设置失败也重新读取，界面回到实际值
        actions.errors["setSystem"] = DeviceError(code: .CONNECTION_FAILED, message: "设置未生效")
        await e.model.setSystem(dev.id, .darkMode(true))
        #expect(actions.calls.suffix(2) == ["setSystem darkMode(true)", "systemSettings com.demo"])
        #expect(e.log.entries.first?.failure == "设置未生效")
        #expect(!e.model.isBusy(dev.id, .system))

        actions.errors = [:]
        await e.model.setSystem(dev.id, .appLocale(package: "com.demo", tag: "ja"))
        #expect(actions.calls.suffix(2).first?.hasPrefix("setSystem appLocale") == true)
        #expect(actions.calls.suffix(1) == ["systemSettings com.demo"])

        await e.model.openSystemLocaleSettings(dev.id)
        #expect(actions.calls.suffix(1) == ["openSystemLocaleSettings"])
        #expect(e.log.entries.first?.title == "打开系统语言设置")
    }

    @Test func customCommandOutputKeptPerCommand() async {
        let actions = RecordingActions()
        actions.shellResult = ShellResult(stdout: "ok\n", stderr: "warn\n", exitCode: 1)
        let dev = device("A")
        let e = make([(dev, actions)])
        e.store.addCommand(name: "强停", command: "am force-stop {package}")
        e.store.addCommand(name: "列表", command: "ls")
        let stop = e.store.commands[0], list = e.store.commands[1]

        await e.model.runCustom(dev.id, stop, package: "com.demo")
        #expect(actions.calls == ["shell am force-stop 'com.demo'"])
        #expect(e.model.lastOutput[stop.id] == actions.shellResult)
        #expect(e.model.lastOutput[list.id] == nil)
        #expect(!e.model.isRunning(dev.id, stop.id))
        #expect(e.log.entries.first?.failure == "退出码 1")

        // 没有结果（如缺少包名）：清掉旧输出，不显示上一次的结果
        await e.model.runCustom(dev.id, stop, package: nil)
        #expect(e.model.lastOutput[stop.id] == nil)

        await e.model.runCustom(dev.id, list, package: nil)
        #expect(e.model.lastOutput[list.id] != nil)
        e.model.removeCommand(list.id)
        #expect(e.store.commands.map(\.id) == [stop.id])
        #expect(e.model.lastOutput[list.id] == nil)
    }
}
