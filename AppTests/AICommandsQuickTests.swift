import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct AICommandsQuickTests {
    private let pixel = AIEnv.pixel
    /// 与 pixel 同一台设备（逻辑 id 相同），经 Wi-Fi 调试连接。
    private let wifiPixel = DeviceInfo(
        serial: "192.168.1.5:5555", platform: .android, name: "Pixel", state: .connected, connection: .wifi,
        hardwareSerial: "HW1", capabilities: AIEnv.pixel.capabilities)

    private func env(hasSession: Bool = true) -> (AIEnv, RecordingActions) {
        let actions = RecordingActions()
        let e = AIEnv(actions: actions, hasSession: hasSession, sleep: { _ in })
        return (e, actions)
    }

    private func asyncCode(_ body: () async throws -> Void) async -> DeviceError? {
        do { try await body() } catch { return error as? DeviceError }
        return nil
    }

    // MARK: 会话与锁定

    @Test func quickActionsDoNotStartSessions() async throws {
        let (e, actions) = env(hasSession: false)
        _ = try await e.commands.currentApp(pixel)
        _ = try await e.commands.launchApp(pixel, package: "com.demo")
        _ = try await e.commands.setNetwork(pixel, kind: .data, on: false)
        _ = try await e.commands.setDevOption(pixel, .showTouches(true))
        _ = try await e.commands.shell(pixel, command: "ls")
        #expect(e.acquired.isEmpty)
        #expect(actions.calls.contains("launchApp com.demo"))
        #expect(actions.calls.contains("shell ls"))
    }

    @Test func lockedQuickActionIsRejected() async throws {
        let (e, actions) = env()
        e.locks.setLocked(pixel.id, true)
        let error = await asyncCode { _ = try await e.commands.clearAppData(pixel, package: "com.demo") }
        #expect(error?.code == .AI_LOCKED)
        #expect(!actions.calls.contains("clearData com.demo"))
        #expect(e.log.entries.first?.title == "clear_app_data com.demo")
        #expect(e.log.entries.first?.failure == "设备已锁定，禁止 AI 操作")
        // 感知类照常可用
        let app = try await e.commands.currentApp(pixel)
        #expect(app.hasPrefix("com.demo"))
        _ = try await e.commands.networkState(pixel)
        _ = try await e.commands.devOptions(pixel)
        _ = try await e.commands.systemSettings(pixel, package: nil)
    }

    @Test func queuedQuickActionRechecksLock() async throws {
        let actions = RecordingActions()
        let e = AIEnv(actions: actions, sleep: { try await Task.sleep(for: $0) })
        e.states[pixel.id] = .running(width: 1080, height: 2400)
        // 先占住设备：长按持续 400ms，快捷操作在其后排队
        let first = Task { try await e.commands.longPress(pixel, .point(x: 288, y: 640), durationMs: 400) }
        try await Task.sleep(for: .milliseconds(100))
        let second = Task { try await e.commands.uninstallApp(pixel, package: "com.demo") }
        try await Task.sleep(for: .milliseconds(50))
        e.locks.setLocked(pixel.id, true)
        _ = try await first.value
        let error = await asyncCode { _ = try await second.value }
        #expect(error?.code == .AI_LOCKED)
        #expect(!actions.calls.contains("uninstall com.demo"))
        #expect(e.log.entries.filter { $0.failure == "设备已锁定，禁止 AI 操作" }.count == 1)
    }

    @Test func aiCannotDisableWifiOverWifi() async throws {
        let (e, actions) = env()
        e.devices = [wifiPixel]
        let error = await asyncCode { _ = try await e.commands.setNetwork(wifiPixel, kind: .wifi, on: false) }
        #expect(error?.code == .UNSUPPORTED)
        #expect(error?.message == "设备经 Wi-Fi 调试连接，关闭 Wi-Fi 会断开连接")
        #expect(actions.calls.isEmpty)
        #expect(e.log.entries.first?.title == "set_network wifi off")
        #expect(e.log.entries.first?.source == .ai)
        #expect(e.log.entries.first?.failure == "设备经 Wi-Fi 调试连接，关闭 Wi-Fi 会断开连接")
        // 打开 Wi-Fi、关闭移动数据不受影响；USB 设备可以关 Wi-Fi
        _ = try await e.commands.setNetwork(wifiPixel, kind: .wifi, on: true)
        _ = try await e.commands.setNetwork(wifiPixel, kind: .data, on: false)
        _ = try await e.commands.setNetwork(pixel, kind: .wifi, on: false)
        #expect(actions.calls == ["setNetwork wifi true", "setNetwork data false", "setNetwork wifi false"])
    }

    // MARK: 文本格式

    @Test func currentAppFormat() async throws {
        let (e, actions) = env()
        actions.foregroundAppResult = AppInfo(package: "com.demo", activity: ".MainActivity", versionName: "1.2.3")
        #expect(try await e.commands.currentApp(pixel) == "com.demo\nActivity: .MainActivity\n版本: 1.2.3")
        actions.foregroundAppResult = AppInfo(package: "com.demo")
        #expect(try await e.commands.currentApp(pixel) == "com.demo\nActivity: 未知\n版本: 未知")
        // 感知类成功不写记录
        #expect(e.log.entries.isEmpty)
    }

    @Test func currentAppFailureIsLogged() async {
        let (e, actions) = env()
        actions.errors["foregroundApp"] = DeviceError(code: .CONNECTION_FAILED, message: "无法识别前台 App")
        let error = await asyncCode { _ = try await e.commands.currentApp(pixel) }
        #expect(error?.code == .CONNECTION_FAILED)
        #expect(e.log.entries.first?.title == "current_app")
        #expect(e.log.entries.first?.failure == "无法识别前台 App")
    }

    @Test func networkStateFormat() async throws {
        let (e, actions) = env()
        actions.networkStateResult = NetworkState(wifi: true, data: false, airplane: nil)
        #expect(try await e.commands.networkState(pixel) == "wifi: on\ndata: off\nairplane: unknown")
    }

    @Test func setNetworkReturnsReadBackState() async throws {
        let (e, actions) = env()
        actions.setNetworkResult = NetworkState(wifi: false, data: true, airplane: false)
        #expect(try await e.commands.setNetwork(pixel, kind: .wifi, on: false) == "wifi: off\ndata: on\nairplane: off")
        #expect(e.log.entries.first?.title == "set_network wifi off")
        #expect(e.log.entries.first?.failure == nil)
    }

    @Test func devOptionsFormat() async throws {
        let (e, actions) = env()
        actions.devOptionsResult = DevOptions(showTouches: true, layoutBounds: false, stayAwake: nil, animationScale: 0.5)
        #expect(
            try await e.commands.devOptions(pixel)
                == "show_touches: on\nlayout_bounds: off\nstay_awake: unknown\nanimation_scale: 0.5")
        actions.devOptionsResult = DevOptions(animationScale: 1.0)
        #expect(try await e.commands.devOptions(pixel).hasSuffix("animation_scale: 1"))
        actions.devOptionsResult = DevOptions()
        #expect(try await e.commands.devOptions(pixel).hasSuffix("animation_scale: unknown"))
    }

    /// 设备读回 inf / 极大数时不能崩溃。
    @Test func nonFiniteDeviceValuesDoNotCrash() async throws {
        let (e, actions) = env()
        actions.devOptionsResult = DevOptions(animationScale: Double("inf"))
        #expect(try await e.commands.devOptions(pixel).hasSuffix("animation_scale: inf"))
        actions.systemSettingsResult = SystemSettings(fontScale: Double("1e30"), appLocaleSupported: true)
        #expect(try await e.commands.systemSettings(pixel, package: nil).hasSuffix("font_scale: 1e+30"))
        actions.systemSettingsResult = SystemSettings(fontScale: .nan, appLocaleSupported: true)
        #expect(try await e.commands.systemSettings(pixel, package: nil).hasSuffix("font_scale: nan"))
    }

    @Test func setDevOptionTitlesAndReadBack() async throws {
        let (e, actions) = env()
        actions.devOptionsResult = DevOptions(showTouches: true, layoutBounds: false, stayAwake: false, animationScale: 1)
        let text = try await e.commands.setDevOption(pixel, .showTouches(true))
        #expect(text == "已设置 show_touches on\nshow_touches: on\nlayout_bounds: off\nstay_awake: off\nanimation_scale: 1")
        _ = try await e.commands.setDevOption(pixel, .layoutBounds(false))
        _ = try await e.commands.setDevOption(pixel, .stayAwake(true))
        _ = try await e.commands.setDevOption(pixel, .animationScale(0.5))
        _ = try await e.commands.setDevOption(pixel, .animationScale(2))
        #expect(
            e.log.entries.map(\.title).reversed() == [
                "set_dev_option show_touches on", "set_dev_option layout_bounds off", "set_dev_option stay_awake on",
                "set_dev_option animation_scale 0.5", "set_dev_option animation_scale 2",
            ])
        #expect(actions.calls.first == "setDevOption \(DevOption.showTouches(true))")
    }

    @Test func setDevOptionSucceedsWhenReadBackFails() async throws {
        let (e, actions) = env()
        actions.errors["devOptions"] = DeviceError(code: .CONNECTION_FAILED, message: "读取失败")
        #expect(try await e.commands.setDevOption(pixel, .stayAwake(true)) == "已设置 stay_awake on")
        #expect(e.log.entries.first?.failure == nil)
    }

    @Test func systemSettingsFormat() async throws {
        let (e, actions) = env()
        actions.systemSettingsResult = SystemSettings(darkMode: true, fontScale: 1.15, appLocaleSupported: true)
        #expect(try await e.commands.systemSettings(pixel, package: nil) == "dark_mode: on\nfont_scale: 1.15")
        #expect(actions.calls.last == "systemSettings -")
        #expect(
            try await e.commands.systemSettings(pixel, package: "com.demo")
                == "dark_mode: on\nfont_scale: 1.15\napp_locale: unknown")
        #expect(actions.calls.last == "systemSettings com.demo")
        actions.systemSettingsResult = SystemSettings(appLocale: "", appLocaleSupported: true)
        #expect(
            try await e.commands.systemSettings(pixel, package: "com.demo")
                == "dark_mode: unknown\nfont_scale: unknown\napp_locale: 跟随系统")
        actions.systemSettingsResult = SystemSettings(fontScale: 1.0, appLocale: "zh-CN", appLocaleSupported: true)
        #expect(try await e.commands.systemSettings(pixel, package: "com.demo").hasSuffix("font_scale: 1\napp_locale: zh-CN"))
        actions.systemSettingsResult = SystemSettings(darkMode: false, appLocaleSupported: false)
        #expect(
            try await e.commands.systemSettings(pixel, package: "com.demo")
                == "dark_mode: off\nfont_scale: unknown\napp_locale: 不支持（需要 Android 13+）")
    }

    @Test func setSystemTitlesAndReadBack() async throws {
        let (e, actions) = env()
        actions.systemSettingsResult = SystemSettings(darkMode: true, fontScale: 1, appLocale: "en", appLocaleSupported: true)
        #expect(try await e.commands.setSystem(pixel, .darkMode(true)) == "已设置 dark_mode on\ndark_mode: on\nfont_scale: 1")
        _ = try await e.commands.setSystem(pixel, .fontScale(1.15))
        let locale = try await e.commands.setSystem(pixel, .appLocale(package: "com.demo", tag: "en"))
        #expect(locale == "已设置 app_locale com.demo en\ndark_mode: on\nfont_scale: 1\napp_locale: en")
        #expect(actions.calls.last == "systemSettings com.demo")
        _ = try await e.commands.setSystem(pixel, .appLocale(package: "com.demo", tag: ""))
        #expect(
            e.log.entries.map(\.title).reversed() == [
                "set_system dark_mode on", "set_system font_scale 1.15", "set_system app_locale com.demo en",
                "set_system app_locale com.demo 跟随系统",
            ])
    }

    @Test func appActionTitlesAndConfirmations() async throws {
        let (e, actions) = env()
        #expect(try await e.commands.launchApp(pixel, package: "com.demo") == "已启动 com.demo")
        _ = try await e.commands.forceStop(pixel, package: "com.demo")
        _ = try await e.commands.clearAppData(pixel, package: "com.demo")
        _ = try await e.commands.uninstallApp(pixel, package: "com.demo")
        _ = try await e.commands.openURL(pixel, url: "https://example.com")
        #expect(
            actions.calls == [
                "launchApp com.demo", "forceStop com.demo", "clearData com.demo", "uninstall com.demo",
                "openURL https://example.com",
            ])
        #expect(
            e.log.entries.map(\.title).reversed() == [
                "launch_app com.demo", "force_stop com.demo", "clear_app_data com.demo", "uninstall_app com.demo",
                "open_url https://example.com",
            ])
        #expect(e.log.entries.allSatisfy { $0.source == .ai && $0.failure == nil })
    }

    @Test func appActionFailureCarriesDeviceOutput() async {
        let (e, actions) = env()
        actions.errors["uninstall"] = DeviceError(code: .CONNECTION_FAILED, message: "Failure [DELETE_FAILED_INTERNAL_ERROR]")
        let error = await asyncCode { _ = try await e.commands.uninstallApp(pixel, package: "com.demo") }
        #expect(error?.message == "Failure [DELETE_FAILED_INTERNAL_ERROR]")
        #expect(e.log.entries.first?.failure == "Failure [DELETE_FAILED_INTERNAL_ERROR]")
    }

    // MARK: shell

    @Test func shellFormatsExitAndStderr() async throws {
        let (e, actions) = env()
        actions.shellResult = ShellResult(stdout: "out\n", stderr: "err\n", exitCode: 1)
        #expect(try await e.commands.shell(pixel, command: "ls /nope") == "exit: 1\nout\n--- stderr ---\nerr\n")
        #expect(actions.shellTimeout == .seconds(30))
        // 退出码非 0 不算失败：AI 要的是原始输出
        #expect(e.log.entries.first?.failure == nil)
        actions.shellResult = ShellResult(stdout: "a", stderr: "", exitCode: 0)
        #expect(try await e.commands.shell(pixel, command: "echo -n a") == "exit: 0\na")
        actions.shellResult = ShellResult(stdout: "a", stderr: "b", exitCode: 0)
        #expect(try await e.commands.shell(pixel, command: "x") == "exit: 0\na\n--- stderr ---\nb")
    }

    @Test func shellOutputIsTruncated() async throws {
        let (e, actions) = env()
        // 多字节字符，验证按字符边界截断
        let stdout = String(repeating: "中a", count: 70 * 1024 / 4)
        actions.shellResult = ShellResult(stdout: stdout, stderr: "", exitCode: 0)
        let text = try await e.commands.shell(pixel, command: "cat big")
        let total = ("exit: 0\n" + stdout).utf8.count
        #expect(total > 65536)
        #expect(text.utf8.count <= 65536)
        #expect(text.utf8.count > 65000)
        #expect(text.contains("已截断"))
        #expect(text.hasSuffix("…（输出已截断，共 \(total) 字节）"))
        #expect(text.hasPrefix("exit: 0\n中a"))
    }

    @Test func shortShellOutputIsNotTruncated() async throws {
        let (e, actions) = env()
        let stdout = String(repeating: "a", count: 65536 - "exit: 0\n".utf8.count)
        actions.shellResult = ShellResult(stdout: stdout, stderr: "", exitCode: 0)
        let text = try await e.commands.shell(pixel, command: "cat")
        #expect(text == "exit: 0\n" + stdout)
    }

    @Test func shellTimeoutCarriesPartialOutput() async {
        let (e, actions) = env()
        let long = String(repeating: "x", count: 5000)
        actions.shellResult = ShellResult(stdout: "partial-line\n" + long, stderr: "", exitCode: 124, timedOut: true)
        let error = await asyncCode { _ = try await e.commands.shell(pixel, command: "sleep 60") }
        #expect(error?.code == .TIMEOUT)
        #expect(error?.message == "shell 命令超时")
        let suggestion = error?.suggestion ?? ""
        #expect(suggestion.hasPrefix("部分输出：\npartial-line"))
        #expect(suggestion.utf8.count == "部分输出：\n".utf8.count + 2048)
        #expect(e.log.entries.first?.title == "shell sleep 60")
        #expect(e.log.entries.first?.failure == "shell 命令超时")
    }

    @Test func shellTitleHasCommand() async throws {
        let (e, actions) = env()
        let command = String(repeating: "命", count: 50) + String(repeating: "c", count: 50)
        _ = try await e.commands.shell(pixel, command: command)
        #expect(e.log.entries.first?.title == "shell " + String(command.prefix(80)))
        #expect(actions.calls == ["shell \(command)"])
        _ = try await e.commands.shell(pixel, command: "getprop ro.build.version.sdk")
        #expect(e.log.entries.first?.title == "shell getprop ro.build.version.sdk")
    }
}
