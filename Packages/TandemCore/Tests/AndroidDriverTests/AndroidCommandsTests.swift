import Testing
import Foundation
import DeviceCore
@testable import AndroidDriver

@Suite struct AndroidCommandsTests {
    @Test func parsesNetworkSettings() {
        #expect(AndroidCommands.Network.parseState("1\n0\n0\n") == NetworkState(wifi: true, data: false, airplane: false))
        #expect(AndroidCommands.Network.parseState("2\nnull\n\n") == NetworkState(wifi: true, data: nil, airplane: nil))
    }

    @Test func setCommands() {
        #expect(AndroidCommands.Network.setCommand(.wifi, on: true) == "svc wifi enable")
        #expect(AndroidCommands.Network.setCommand(.data, on: false) == "svc data disable")
        #expect(AndroidCommands.Network.setCommand(.airplane, on: true) == "cmd connectivity airplane-mode enable")
    }

    /// 用真实 /bin/sh 验证转义后的参数原样回显。
    @Test func quoteNeutralizesInjection() throws {
        let input = "x'; reboot; echo '"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s \(ShellQuote.quote(input))"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(String(decoding: data, as: UTF8.self) == input)
    }
}

@Suite struct AndroidSettingsCommandsTests {
    @Test func parsesDevOptions() {
        let on = AndroidCommands.DevSettings.parse("1\ntrue\n7\n0.5\n")
        #expect(on == DevOptions(showTouches: true, layoutBounds: true, stayAwake: true, animationScale: 0.5))
        let off = AndroidCommands.DevSettings.parse("null\n\n0\nnull\n")
        #expect(off == DevOptions(showTouches: nil, layoutBounds: nil, stayAwake: false, animationScale: 1))
    }

    @Test func devSetCommands() throws {
        #expect(try AndroidCommands.DevSettings.setCommand(.showTouches(true)) == "settings put system show_touches 1")
        #expect(try AndroidCommands.DevSettings.setCommand(.layoutBounds(false)) == "setprop debug.layout false; service call activity 1599295570 > /dev/null")
        #expect(try AndroidCommands.DevSettings.setCommand(.stayAwake(true)) == "settings put global stay_on_while_plugged_in 7")
    }

    @Test func animationScaleSetsAllThree() throws {
        let cmd = try AndroidCommands.DevSettings.setCommand(.animationScale(2))
        for key in ["window_animation_scale", "transition_animation_scale", "animator_duration_scale"] {
            #expect(cmd.contains("settings put global \(key) 2"))
        }
        #expect(throws: DeviceError.self) { try AndroidCommands.DevSettings.setCommand(.animationScale(3)) }
    }

    @Test func parsesNightAndLocales() {
        #expect(AndroidCommands.System.parseNight("Night mode: yes\n") == true)
        #expect(AndroidCommands.System.parseNight("Night mode: no\n") == false)
        #expect(AndroidCommands.System.parseNight("Night mode: auto\n") == nil)
        #expect(AndroidCommands.System.parseFontScale("1.15\n") == 1.15)
        #expect(AndroidCommands.System.parseFontScale("null\n") == nil)
        #expect(AndroidCommands.System.parseAppLocales("Locales for com.demo for user 0 are [zh-CN]\n") == "zh-CN")
        #expect(AndroidCommands.System.parseAppLocales("Locales for com.demo for user 0 are []\n") == "")
        #expect(AndroidCommands.System.parseAppLocales("garbage") == nil)
    }

    @Test func localeTagValidated() throws {
        for tag in ["zh-CN", "en", ""] {
            let cmd = try AndroidCommands.System.setCommand(.appLocale(package: "com.demo", tag: tag))
            #expect(cmd == "cmd locale set-app-locales com.demo --locales \(ShellQuote.quote(tag))")
        }
        #expect(try AndroidCommands.System.setCommand(.darkMode(true)) == "cmd uimode night yes")
        #expect(try AndroidCommands.System.setCommand(.fontScale(1.15)) == "settings put system font_scale 1.15")
        #expect(throws: DeviceError.self) { try AndroidCommands.System.setCommand(.fontScale(2)) }
        do {
            _ = try AndroidCommands.System.setCommand(.appLocale(package: "com.demo", tag: "zh;reboot"))
            Issue.record("应抛错")
        } catch let e as DeviceError { #expect(e.code == .INVALID_ARGUMENT) }
    }
}

@Suite struct AndroidLogsTests {
    private func fixtureLines() throws -> [String] {
        let url = try #require(Bundle.module.url(forResource: "logcat-threadtime-samsung", withExtension: "txt", subdirectory: "Fixtures"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @Test func parsesThreadtime() throws {
        let lines = try fixtureLines()
        var parsed = 0
        for line in lines {
            if line.hasPrefix("---------") {
                #expect(AndroidCommands.Logs.parse(line) == nil)
            } else {
                #expect(AndroidCommands.Logs.parse(line) != nil, "\(line)")
                parsed += 1
            }
        }
        #expect(parsed > 200)
        let first = try #require(AndroidCommands.Logs.parse("10-18 23:21:47.444   843 17362 I sensors-hal: handle_sns_client_event:660, x"))
        #expect(first == LogEntry(time: "10-18 23:21:47.444", pid: 843, tid: 17362, level: .info,
                                  tag: "sensors-hal", message: "handle_sns_client_event:660, x"))
    }

    @Test func tagWithSpacesAndColons() throws {
        let e = try #require(AndroidCommands.Logs.parse("10-18 22:01:02.345  1234  1250 I Some Tag: a: b"))
        #expect(e.tag == "Some Tag")
        #expect(e.message == "a: b")
    }

    @Test func emptyMessageAndCRLF() throws {
        let empty = try #require(AndroidCommands.Logs.parse("10-18 22:01:02.345  1234  1250 D MyTag:"))
        #expect(empty.tag == "MyTag")
        #expect(empty.message == "")
        let crlf = try #require(AndroidCommands.Logs.parse("10-18 22:01:02.345  1234  1250 W MyTag: hello\r"))
        #expect(crlf.message == "hello")
        let crlfEmpty = try #require(AndroidCommands.Logs.parse("10-18 22:01:02.345  1234  1250 W MyTag:\r\n"))
        #expect(crlfEmpty.message == "")
        #expect(AndroidCommands.Logs.parse("") == nil)
        #expect(AndroidCommands.Logs.parse("--------- beginning of main") == nil)
    }

    @Test func startProcBothForms() {
        func am(_ pid: Int, _ msg: String) -> LogEntry {
            LogEntry(time: "t", pid: 1, tid: 1, level: .info, tag: "ActivityManager", message: msg)
        }
        let entries = [
            am(0, "Start proc 4321:com.demo/u0a123 for activity {com.demo/.Main}"),
            am(0, "Start proc 5555:com.demo:remote/u0a123 for service"),
            am(0, "Start proc 6001:com.demox/u0a124 for activity"),
            am(0, "Start proc 7001:comXdemo/u0a124 for activity"),
            am(0, "Start proc 4321:com.demo/u0a123 for broadcast"),
            LogEntry(time: "t", pid: 1, tid: 1, level: .info, tag: "Other", message: "Start proc 9999:com.demo/u0a1"),
        ]
        #expect(AndroidCommands.Logs.startProcPids(entries, package: "com.demo") == [4321, 5555])
    }

    @Test func startProcFromFixture() throws {
        let entries = try fixtureLines().compactMap(AndroidCommands.Logs.parse)
        #expect(AndroidCommands.Logs.startProcPids(entries, package: "com.demo") == [4321, 5555])
    }

    @Test func levelArgumentIsQuoted() {
        #expect(AndroidCommands.Logs.snapshotCommand(minLevel: .warn) == "logcat -d -v threadtime '*:W'")
    }
}
