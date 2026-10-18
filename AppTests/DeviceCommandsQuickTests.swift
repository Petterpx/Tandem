import AppKit
import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct DeviceCommandsQuickTests {
    private struct Env {
        let commands: DeviceCommands
        let log: ActivityLog
        let actions: RecordingActions
        let quick: QuickActionsStore
    }

    private let dev = DeviceInfo(
        serial: "s1", platform: .android, name: "Pixel", state: .connected, connection: .usb,
        hardwareSerial: "HW1", capabilities: [.screenshot])

    private func make(actions: RecordingActions = RecordingActions()) -> Env {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let mac = MacPasteboard(NSPasteboard(name: .init(UUID().uuidString)))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = CaptureStore(pasteboard: mac, defaults: defaults, home: home)
        let log = ActivityLog()
        let device = dev
        let commands = DeviceCommands(
            runner: ActionRunner(log: log), store: store, recording: RecordingService(store: store),
            clipboard: ClipboardService(pasteboard: mac, defaults: defaults), toasts: ToastCenter(),
            device: { $0 == device.id ? device : nil }, session: { _ in nil },
            actions: { $0 == device.id ? actions : nil }, isPopupOpen: { _ in false })
        return Env(commands: commands, log: log, actions: actions,
                   quick: QuickActionsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!))
    }

    @Test func setNetworkLogsTitle() async {
        let e = make()
        let state = await e.commands.setNetwork(dev.id, .wifi, on: false)
        #expect(state?.wifi == false)
        _ = await e.commands.setNetwork(dev.id, .data, on: true)
        _ = await e.commands.setNetwork(dev.id, .airplane, on: true)
        #expect(e.log.entries.map(\.title) == ["开启飞行模式", "打开移动数据", "关闭 Wi-Fi"])
        #expect(e.log.entries.allSatisfy { $0.source == .user && $0.failure == nil })
    }

    @Test func restartStopsThenLaunches() async {
        let e = make()
        let ok = await e.commands.appAction(dev.id, .restart, package: "com.demo")
        #expect(ok)
        #expect(e.actions.calls == ["forceStop com.demo", "launchApp com.demo"])
        #expect(e.log.entries.map(\.title) == ["重启 com.demo"])
    }

    @Test func openURLRecordsHistoryOnSuccessOnly() async {
        let e = make()
        #expect(await e.commands.openURL(dev.id, "https://a.com", store: e.quick))
        #expect(e.quick.urlHistory == ["https://a.com"])
        #expect(e.log.entries.first?.title == "打开链接 https://a.com")
        e.actions.errors["openURL"] = DeviceError(code: .UNSUPPORTED, message: "不支持")
        #expect(await e.commands.openURL(dev.id, "https://b.com", store: e.quick) == false)
        #expect(e.quick.urlHistory == ["https://a.com"])
        #expect(e.log.entries.first?.failure == "不支持")
    }

    @Test func customCommandFailureStillReturnsOutput() async {
        let e = make()
        e.actions.shellResult = ShellResult(stdout: "out", stderr: "err", exitCode: 2)
        let c = CustomCommand(id: UUID(), name: "测试", command: "ls {package}")
        let r = await e.commands.runCustom(dev.id, c, package: "com.demo")
        #expect(r?.stdout == "out")
        #expect(e.actions.calls == ["shell ls 'com.demo'"])
        #expect(e.log.entries.map(\.title) == ["执行：测试"])
        #expect(e.log.entries.first?.failure == "退出码 2")

        e.actions.shellResult = ShellResult(stdout: "", stderr: "", exitCode: -1, timedOut: true)
        _ = await e.commands.runCustom(dev.id, c, package: "com.demo")
        #expect(e.log.entries.first?.failure == "超时")

        e.actions.shellResult = ShellResult(stdout: "", stderr: "", exitCode: 0)
        _ = await e.commands.runCustom(dev.id, c, package: "com.demo")
        #expect(e.log.entries.first?.failure == nil)

        // 渲染失败：记录失败并返回 nil
        #expect(await e.commands.runCustom(dev.id, c, package: nil) == nil)
        #expect(e.log.entries.first?.failure == "该命令需要目标 App")
    }

    @Test func readsDoNotLog() async {
        let e = make()
        _ = await e.commands.readNetwork(dev.id)
        _ = await e.commands.readForegroundApp(dev.id)
        _ = await e.commands.readDevOptions(dev.id)
        let sys = await e.commands.readSystem(dev.id, appPackage: nil)
        #expect(e.log.entries.isEmpty)
        #expect((try? sys.get())?.appLocaleSupported == true)
        e.actions.errors["networkState"] = CancellationError()
        if case .failure(let err) = await e.commands.readNetwork(dev.id) {
            #expect(err.code == .CONNECTION_FAILED)
        } else { Issue.record("应失败") }
        #expect(e.log.entries.isEmpty)
    }

    @Test func titlesForDevOptionsAndSystem() async {
        let e = make()
        _ = await e.commands.setDevOption(dev.id, .showTouches(true))
        _ = await e.commands.setDevOption(dev.id, .animationScale(0.5))
        _ = await e.commands.setDevOption(dev.id, .animationScale(0))
        _ = await e.commands.setDevOption(dev.id, .animationScale(2))
        _ = await e.commands.setSystem(dev.id, .darkMode(false))
        _ = await e.commands.setSystem(dev.id, .fontScale(1.15))
        _ = await e.commands.setSystem(dev.id, .appLocale(package: "com.demo", tag: "zh-CN"))
        _ = await e.commands.setSystem(dev.id, .appLocale(package: "com.demo", tag: ""))
        await e.commands.openSystemLocaleSettings(dev.id)
        #expect(e.log.entries.map(\.title).reversed() == [
            "显示触摸点：开", "动画倍速：0.5x", "动画倍速：关", "动画倍速：2x", "深色模式：关",
            "字体大小：1.15", "App 语言 com.demo：zh-CN", "App 语言 com.demo：跟随系统", "打开系统语言设置",
        ])
    }

    @Test func unavailableActionsReportDeviceNotFound() async {
        let e = make()
        let ok = await e.commands.appAction("missing", .launch, package: "com.demo")
        #expect(ok == false)
        let r = await e.commands.readNetwork("missing")
        if case .failure(let err) = r { #expect(err.code == .DEVICE_NOT_FOUND) } else { Issue.record("应失败") }
    }

    @Test func wifiOffOverWifiNeedsConfirmation() {
        let wifi = DeviceInfo(
            serial: "s2", platform: .android, name: "P", state: .connected, connection: .wifi,
            hardwareSerial: "HW2", capabilities: [])
        #expect(DeviceCommands.needsWifiConfirmation(wifi, kind: .wifi, on: false))
        #expect(!DeviceCommands.needsWifiConfirmation(wifi, kind: .wifi, on: true))
        #expect(!DeviceCommands.needsWifiConfirmation(wifi, kind: .data, on: false))
        #expect(!DeviceCommands.needsWifiConfirmation(dev, kind: .wifi, on: false))
    }
}
