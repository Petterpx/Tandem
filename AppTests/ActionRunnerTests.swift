import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct ActionRunnerTests {
    let log = ActivityLog()
    let runner: ActionRunner
    let dev = DeviceInfo(serial: "s1", platform: .android, name: "Pixel", state: .connected, connection: .usb, hardwareSerial: "HW1")
    let other = DeviceInfo(serial: "s2", platform: .android, name: "Galaxy", state: .connected, connection: .usb, hardwareSerial: "HW2")

    init() { runner = ActionRunner(log: log) }

    @Test func successIsLoggedWithSource() async {
        let v = await runner.perform("截图", device: dev, source: .ai) { 42 }
        #expect(v == 42)
        #expect(log.entries.first?.title == "截图" && log.entries.first?.source == .ai && log.entries.first?.failure == nil)
        #expect(log.entries.first?.deviceName == "Pixel")
    }

    @Test func deviceErrorIsLoggedAndShown() async {
        let v: Int? = await runner.perform("读取剪贴板", device: dev) { throw DeviceError.connectionFailed("会话未运行") }
        #expect(v == nil)
        #expect(log.entries.first?.failure == "连接失败：会话未运行")
        #expect(runner.lastError == PanelError(deviceID: dev.id, message: "连接失败：会话未运行", suggestion: "请确认设备已开启调试并与电脑处于同一网络"))
    }

    @Test func localizedErrorUsesDescriptionAndSuggestion() async {
        let url = URL(fileURLWithPath: "/nope")
        let _: Int? = await runner.perform("截图", device: dev) { throw CaptureError.cannotWrite(url) }
        #expect(runner.lastError?.message.hasPrefix("无法写入") == true)
        #expect(runner.lastError?.suggestion == "请在设置中更换保存目录")
    }

    @Test func successClearsOnlySameDeviceError() async {
        let _: Int? = await runner.perform("a", device: dev) { throw DeviceError.connectionFailed("x") }
        await runner.perform("b", device: other) { 1 }
        #expect(runner.lastError?.deviceID == dev.id)
        await runner.perform("c", device: dev) { 1 }
        #expect(runner.lastError == nil)
    }

    @Test func aiFailureDoesNotTouchPanelError() async {
        let _: Int? = await runner.perform("a", device: dev) { throw DeviceError.connectionFailed("user") }
        let before = runner.lastError
        let v: Int? = await runner.perform("b", device: dev, source: .ai) { throw DeviceError.connectionFailed("ai") }
        #expect(v == nil)
        #expect(runner.lastError == before)
        #expect(log.entries.count == 2)
        #expect(log.entries.first?.source == .ai && log.entries.first?.failure == "连接失败：ai")
    }

    @Test func aiSuccessDoesNotClearPanelError() async {
        let _: Int? = await runner.perform("a", device: dev) { throw DeviceError.connectionFailed("user") }
        let before = runner.lastError
        await runner.perform("b", device: dev, source: .ai) { 1 }
        await runner.perform("c", device: dev, source: .ai, logSuccess: false) { 1 }
        #expect(runner.lastError == before && before != nil)
    }

    @Test func quietSuccessIsNotLogged() async {
        await runner.perform("静默", device: dev, logSuccess: false) { 1 }
        #expect(log.entries.isEmpty)
        let _: Int? = await runner.perform("静默", device: dev, logSuccess: false) { throw DeviceError.connectionFailed("x") }
        #expect(log.entries.count == 1)
    }

    @Test func noteOnlyLogs() {
        runner.note("自动同步", device: dev, source: .ai, failure: "失败")
        #expect(log.entries.count == 1 && log.entries[0].failure == "失败" && runner.lastError == nil)
    }

    @Test func dismissErrorClears() async {
        let _: Int? = await runner.perform("a", device: dev) { throw DeviceError.connectionFailed("x") }
        runner.dismissError()
        #expect(runner.lastError == nil)
    }

    @Test func logIsCappedAt500() {
        for i in 0..<501 {
            log.append(ActivityEntry(id: UUID(), date: Date(), source: .user, deviceName: "d", title: "\(i)", failure: nil))
        }
        #expect(log.entries.count == 500)
        #expect(log.entries.first?.title == "500")
        log.clear()
        #expect(log.entries.isEmpty)
    }
}
