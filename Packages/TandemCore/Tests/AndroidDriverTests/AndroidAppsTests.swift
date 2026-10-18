import Testing
import Foundation
import DeviceCore
@testable import AndroidDriver

private let adbURL = URL(fileURLWithPath: "/fake/adb")
private let adbPath = adbURL.path

private func actions(_ runner: FakeProcessRunner) -> AndroidActions {
    AndroidActions(serial: "S", adb: AdbClient(adb: Adb(url: adbURL, version: "1"), runner: runner), settleDelay: .zero)
}

private func shellArgs(_ cmd: String) -> [String] { ["-s", "S", "shell", cmd] }

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

private func expectError(_ code: DeviceError.Code, _ message: String? = nil, _ body: () async throws -> Void) async {
    do {
        try await body()
        Issue.record("应抛错")
    } catch let error as DeviceError {
        #expect(error.code == code)
        if let message { #expect(error.message.contains(message)) }
    } catch {
        Issue.record("错误类型不对：\(error)")
    }
}

@Suite struct AndroidAppsTests {
    @Test func parsesSamsungForeground() throws {
        let r = try #require(AndroidCommands.Apps.parseForeground(try fixture("dumpsys-activities-samsung")))
        #expect(r.package == "com.demo")
        #expect(r.activity == "com.demo.MainActivity")
    }

    @Test func parsesAospForeground() throws {
        let r = try #require(AndroidCommands.Apps.parseForeground(try fixture("dumpsys-activities-aosp")))
        #expect(r.package == "com.demo")
        #expect(r.activity == "com.demo.MainActivity")
    }

    @Test func parsesVersionAndComponent() {
        #expect(AndroidCommands.Apps.parseVersionName("    versionName=1.2.3\n") == "1.2.3")
        #expect(AndroidCommands.Apps.parseVersionName("") == nil)
        #expect(AndroidCommands.Apps.parseLaunchComponent("priority=0\ncom.demo/.Main\n\n") == "com.demo/.Main")
        #expect(AndroidCommands.Apps.parseLaunchComponent("No activity found") == nil)
    }

    @Test func foregroundReadsVersion() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, shellArgs(AndroidCommands.Apps.foregroundCommand), stdout: try fixture("dumpsys-activities-samsung"))
        runner.stub(adbPath, shellArgs(AndroidCommands.Apps.homeCommand), stdout: try fixture("resolve-home-samsung"))
        runner.stub(adbPath, shellArgs("dumpsys package com.demo | grep -m1 versionName"), stdout: "    versionName=2.0\n")
        let info = try await actions(runner).foregroundApp()
        #expect(info == AppInfo(package: "com.demo", activity: "com.demo.MainActivity", versionName: "2.0"))
    }

    @Test func parsesHomePackage() throws {
        #expect(AndroidCommands.Apps.parseHomePackage(try fixture("resolve-home-samsung")) == "com.sec.android.app.launcher")
        #expect(AndroidCommands.Apps.parseHomePackage("No activity found\n") == nil)
        #expect(AndroidCommands.Apps.parseHomePackage("") == nil)
    }

    /// 桌面上前台是 launcher：不能当成目标 App（清数据会清掉桌面布局）。
    @Test func launcherForegroundIsError() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, shellArgs(AndroidCommands.Apps.foregroundCommand), stdout: try fixture("dumpsys-activities-launcher"))
        runner.stub(adbPath, shellArgs(AndroidCommands.Apps.homeCommand), stdout: try fixture("resolve-home-samsung"))
        await expectError(.CONNECTION_FAILED, "无法识别前台 App") { _ = try await actions(runner).foregroundApp() }
    }

    @Test func systemUIForegroundIsError() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, shellArgs(AndroidCommands.Apps.foregroundCommand),
                    stdout: "  ResumedActivity: ActivityRecord{1 u0 com.android.systemui/.keyguard.KeyguardActivity t2}\n")
        runner.stub(adbPath, shellArgs(AndroidCommands.Apps.homeCommand), stdout: try fixture("resolve-home-samsung"))
        await expectError(.CONNECTION_FAILED, "无法识别前台 App") { _ = try await actions(runner).foregroundApp() }
    }

    /// 解析不出桌面包名时跳过这一检查，普通 App 照常识别。
    @Test func unresolvableHomeSkipsCheck() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, shellArgs(AndroidCommands.Apps.foregroundCommand), stdout: try fixture("dumpsys-activities-aosp"))
        runner.stub(adbPath, shellArgs(AndroidCommands.Apps.homeCommand), stdout: "No activity found\n")
        runner.stub(adbPath, shellArgs("dumpsys package com.demo | grep -m1 versionName"), stdout: "")
        let info = try await actions(runner).foregroundApp()
        #expect(info.package == "com.demo")
    }

    @Test func foregroundUnparsableIsError() async {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, shellArgs(AndroidCommands.Apps.foregroundCommand), stdout: "", exitCode: 1)
        await expectError(.CONNECTION_FAILED, "无法识别前台 App") { _ = try await actions(runner).foregroundApp() }
    }

    @Test func launchUsesResolvedComponent() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, shellArgs("cmd package resolve-activity --brief -c android.intent.category.LAUNCHER com.demo"),
                    stdout: "priority=0 preferredOrder=0\ncom.demo/.Main\n")
        runner.stub(adbPath, shellArgs("am start -n 'com.demo/.Main'"), stdout: "Starting: Intent")
        try await actions(runner).launchApp("com.demo")
        #expect(runner.calls.contains { $0.args == shellArgs("am start -n 'com.demo/.Main'") })
    }

    @Test func launchQuotesInnerClassComponent() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, shellArgs("cmd package resolve-activity --brief -c android.intent.category.LAUNCHER com.demo"), stdout: "com.demo/com.demo.Main$Launcher\n")
        runner.stub(adbPath, shellArgs("am start -n 'com.demo/com.demo.Main$Launcher'"), stdout: "Starting: Intent")
        try await actions(runner).launchApp("com.demo")
        #expect(AndroidCommands.Apps.parseLaunchComponent("com.x/.Main;reboot") == nil)
        #expect(AndroidCommands.Apps.parseLaunchComponent("com.x/$(id)") == nil)
    }

    @Test func successEchoContainingErrorIsNotFailure() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, shellArgs("cmd package resolve-activity --brief -c android.intent.category.LAUNCHER com.demo"), stdout: "com.demo/.ErrorActivity\n")
        runner.stub(adbPath, shellArgs("am start -n 'com.demo/.ErrorActivity'"), stdout: "Starting: Intent { cmp=com.demo/.ErrorActivity }\n")
        try await actions(runner).launchApp("com.demo")

        let url = "https://x.com/Error-page"
        let r2 = FakeProcessRunner()
        r2.stub(adbPath, shellArgs("am start -a android.intent.action.VIEW -d " + ShellQuote.quote(url)),
                stdout: "Starting: Intent { act=android.intent.action.VIEW dat=https://x.com/Error-page }\n")
        try await actions(r2).openURL(url)
    }

    @Test func errorLineStillFailsOpenURL() async {
        let url = "https://x.com/a"
        let runner = FakeProcessRunner()
        runner.stub(adbPath, shellArgs("am start -a android.intent.action.VIEW -d " + ShellQuote.quote(url)), stdout: "Error: Activity not started\n")
        await expectError(.CONNECTION_FAILED, "Error: Activity not started") { try await actions(runner).openURL(url) }
    }

    @Test func launchWithoutLauncherActivityFails() async {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, shellArgs("cmd package resolve-activity --brief -c android.intent.category.LAUNCHER com.demo"), stdout: "No activity found\n")
        await expectError(.CONNECTION_FAILED, "该应用没有可启动的界面") { try await actions(runner).launchApp("com.demo") }
    }

    @Test func launchErrorOnStderrFails() async {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, shellArgs("cmd package resolve-activity --brief -c android.intent.category.LAUNCHER com.demo"), stdout: "com.demo/.Main\n")
        runner.stub(adbPath, shellArgs("am start -n 'com.demo/.Main'"), stdout: "", stderr: "Error type 3\n")
        await expectError(.CONNECTION_FAILED, "Error type 3") { try await actions(runner).launchApp("com.demo") }
    }

    @Test func stderrNoiseDoesNotCorruptResolve() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, shellArgs("cmd package resolve-activity --brief -c android.intent.category.LAUNCHER com.demo"),
                    stdout: "com.demo/.Main\n", stderr: "warning: a/b noise\n")
        runner.stub(adbPath, shellArgs("am start -n 'com.demo/.Main'"), stdout: "Starting: Intent")
        try await actions(runner).launchApp("com.demo")
    }

    @Test func forceStopRuns() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, shellArgs("am force-stop com.demo"))
        try await actions(runner).forceStop("com.demo")
        #expect(runner.calls.count == 1)
    }

    @Test func clearDataNeedsSuccess() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, shellArgs("pm clear com.demo"), stdout: "Success\n")
        try await actions(runner).clearData("com.demo")
    }

    @Test func uninstallFailureCarriesOutput() async {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, shellArgs("pm uninstall com.demo"), stdout: "Failure [DELETE_FAILED_INTERNAL_ERROR]\n", exitCode: 1)
        await expectError(.CONNECTION_FAILED, "Failure [DELETE_FAILED_INTERNAL_ERROR]") { try await actions(runner).uninstall("com.demo") }
    }

    @Test func openURLQuotesAndReportsUnresolvable() async throws {
        let runner = FakeProcessRunner()
        let cmd = "am start -a android.intent.action.VIEW -d " + ShellQuote.quote("https://a.b/?x=1&y='z'")
        runner.stub(adbPath, shellArgs(cmd), stdout: "Starting: Intent")
        try await actions(runner).openURL("https://a.b/?x=1&y='z'")
        #expect(runner.calls.last?.args.last?.contains(#"'https://a.b/?x=1&y='\''z'\'''"#) == true)

        let bad = FakeProcessRunner()
        bad.stub(adbPath, shellArgs(cmd), stdout: "", stderr: "Error: Activity not started, unable to resolve Intent { act=android.intent.action.VIEW }\n")
        await expectError(.CONNECTION_FAILED, "没有应用能打开该链接") { try await actions(bad).openURL("https://a.b/?x=1&y='z'") }
    }

    @Test func invalidPackageIsRejectedBeforeAdb() async {
        let runner = FakeProcessRunner()
        await expectError(.INVALID_ARGUMENT) { try await actions(runner).clearData("x;reboot") }
        #expect(runner.calls.isEmpty)
    }
}
