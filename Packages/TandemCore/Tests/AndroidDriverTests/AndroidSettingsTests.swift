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
private let sdkArgs = shellArgs("getprop ro.build.version.sdk")

@Suite struct AndroidSettingsTests {
    @Test func devOptionsReads() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, shellArgs(AndroidCommands.DevSettings.readCommand), stdout: "1\ntrue\n7\n0.5\n")
        let o = try await actions(runner).devOptions()
        #expect(o == DevOptions(showTouches: true, layoutBounds: true, stayAwake: true, animationScale: 0.5))
    }

    @Test func setDevOptionRuns() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, shellArgs("settings put system show_touches 1"))
        try await actions(runner).setDevOption(.showTouches(true))
        #expect(runner.calls.count == 1)
    }

    @Test func appLocaleNeedsAndroid13() async {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, sdkArgs, stdout: "32\n")
        do {
            try await actions(runner).setSystem(.appLocale(package: "com.demo", tag: "en"))
            Issue.record("应抛错")
        } catch let e as DeviceError {
            #expect(e.code == .UNSUPPORTED)
            #expect(e.message.contains("Android 13+"))
        } catch { Issue.record("错误类型不对：\(error)") }
        #expect(!runner.calls.contains { $0.args.contains { $0.contains("cmd locale") } })
    }

    @Test func invalidLocaleTagNoAdbCall() async {
        let runner = FakeProcessRunner()
        do {
            try await actions(runner).setSystem(.appLocale(package: "com.demo", tag: "zh;reboot"))
            Issue.record("应抛错")
        } catch let e as DeviceError { #expect(e.code == .INVALID_ARGUMENT) } catch {}
        #expect(runner.calls.isEmpty)
    }

    @Test func appLocaleSets() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, sdkArgs, stdout: "33\n")
        runner.stub(adbPath, shellArgs("cmd locale set-app-locales com.demo --locales 'zh-CN'"))
        try await actions(runner).setSystem(.appLocale(package: "com.demo", tag: "zh-CN"))
    }

    @Test func systemSettingsReads() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, sdkArgs, stdout: "33\n")
        runner.stub(adbPath, shellArgs(AndroidCommands.System.nightCommand), stdout: "Night mode: yes\n")
        runner.stub(adbPath, shellArgs(AndroidCommands.System.fontScaleCommand), stdout: "null\n")
        runner.stub(adbPath, shellArgs("cmd locale get-app-locales com.demo"), stdout: "Locales for com.demo for user 0 are [en]\n")
        let s = try await actions(runner).systemSettings(appPackage: "com.demo")
        #expect(s == SystemSettings(darkMode: true, fontScale: 1.0, appLocale: "en", appLocaleSupported: true))
    }

    @Test func systemSettingsOldSdkSkipsLocale() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, sdkArgs, stdout: "31\n")
        runner.stub(adbPath, shellArgs(AndroidCommands.System.nightCommand), stdout: "Night mode: no\n")
        runner.stub(adbPath, shellArgs(AndroidCommands.System.fontScaleCommand), stdout: "1.15\n")
        let s = try await actions(runner).systemSettings(appPackage: "com.demo")
        #expect(s == SystemSettings(darkMode: false, fontScale: 1.15, appLocale: nil, appLocaleSupported: false))
        #expect(!runner.calls.contains { $0.args.contains { $0.contains("cmd locale") } })
    }

    /// `cmd uimode night` 输出空或多行时，字体缩放仍按自己的命令读取。
    @Test func fontScaleIndependentOfNightOutput() async throws {
        for night in ["", "Night mode: yes\nCustom: none\n"] {
            let runner = FakeProcessRunner()
            runner.stub(adbPath, sdkArgs, stdout: "31\n")
            runner.stub(adbPath, shellArgs(AndroidCommands.System.nightCommand), stdout: night)
            runner.stub(adbPath, shellArgs(AndroidCommands.System.fontScaleCommand), stdout: "1.3\n")
            let s = try await actions(runner).systemSettings(appPackage: nil)
            #expect(s.fontScale == 1.3)
            #expect(s.darkMode == (night.isEmpty ? nil : true))
        }
    }

    @Test func systemSettingsRejectsBadPackage() async {
        let runner = FakeProcessRunner()
        do {
            _ = try await actions(runner).systemSettings(appPackage: "x; reboot")
            Issue.record("应抛错")
        } catch let e as DeviceError { #expect(e.code == .INVALID_ARGUMENT) } catch {}
        #expect(runner.calls.isEmpty)
    }

    @Test func opensLocaleSettings() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, shellArgs("am start -a android.settings.LOCALE_SETTINGS"), stdout: "Starting: Intent\n")
        try await actions(runner).openSystemLocaleSettings()
    }
}
