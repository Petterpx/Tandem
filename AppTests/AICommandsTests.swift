import AppKit
import DeviceCore
import Foundation
import os
import Testing
@testable import Tandem

@MainActor
@Suite struct AICommandsTests {
    private let pixel = AIEnv.pixel

    private func device(_ name: String, serial: String, hw: String, state: DeviceState = .connected) -> DeviceInfo {
        DeviceInfo(serial: serial, platform: .android, name: name, state: state, connection: .usb, hardwareSerial: hw)
    }

    private func code(_ body: () throws -> Void) -> DeviceError? {
        do { try body() } catch { return error as? DeviceError }
        return nil
    }

    private func asyncCode(_ body: () async throws -> Void) async -> DeviceError? {
        do { try await body() } catch { return error as? DeviceError }
        return nil
    }

    // MARK: 设备解析

    @Test func omittedDeviceWithOneConnected() throws {
        let e = AIEnv(devices: [pixel, device("Old", serial: "s2", hw: "HW2", state: .offline)])
        #expect(try e.commands.resolve(nil).id == pixel.id)
    }

    @Test func omittedDeviceWithNoneConnected() {
        let e = AIEnv(devices: [device("Old", serial: "s2", hw: "HW2", state: .offline)])
        let error = code { _ = try e.commands.resolve(nil) }
        #expect(error?.code == .DEVICE_NOT_FOUND && error?.message == "没有已连接的设备")
    }

    @Test func omittedDeviceWithTwoIsAmbiguous() {
        let e = AIEnv(devices: [pixel, device("Galaxy", serial: "s2", hw: "HW2")])
        let error = code { _ = try e.commands.resolve(nil) }
        #expect(error?.code == .DEVICE_AMBIGUOUS)
        #expect(error?.message == "连接了多台设备，请用 device 参数指定：Pixel（HW1）、Galaxy（HW2）")
    }

    @Test func resolveByIDAndSerial() throws {
        let e = AIEnv(devices: [pixel, device("Galaxy", serial: "s2", hw: "HW2")])
        #expect(try e.commands.resolve("HW2").name == "Galaxy")
        #expect(try e.commands.resolve("s1").id == pixel.id)
        #expect(code { _ = try e.commands.resolve("nope") }?.code == .DEVICE_NOT_FOUND)
    }

    @Test func resolveByNameCaseInsensitive() throws {
        let e = AIEnv(devices: [pixel, device("Galaxy", serial: "s2", hw: "HW2")])
        #expect(try e.commands.resolve("pixel").id == pixel.id)
        e.devices = [pixel, device("Pixel", serial: "s2", hw: "HW2")]
        let error = code { _ = try e.commands.resolve("PIXEL") }
        #expect(error?.code == .DEVICE_AMBIGUOUS)
        #expect(error?.message.contains("HW1") == true && error?.message.contains("HW2") == true)
    }

    @Test func unauthorizedIsReported() {
        let e = AIEnv(devices: [device("Pixel", serial: "s1", hw: "HW1", state: .unauthorized)])
        let error = code { _ = try e.commands.resolve("HW1") }
        #expect(error?.code == .DEVICE_UNAUTHORIZED && error?.message == "请在手机上允许 USB 调试")
    }

    @Test func offlineIsReportedAsDisconnected() {
        let e = AIEnv(devices: [device("Pixel", serial: "s1", hw: "HW1", state: .offline)])
        let error = code { _ = try e.commands.resolve("Pixel") }
        #expect(error?.code == .DEVICE_NOT_FOUND && error?.message == "设备已断开")
    }

    // MARK: 会话就绪

    @Test func runningSessionIsReturnedWithoutAcquire() async throws {
        let e = AIEnv()
        let session = try await e.commands.runningSession(pixel)
        #expect(session === e.fake && e.acquired.isEmpty)
    }

    @Test func sessionIsAcquiredAndAwaited() async throws {
        let e = AIEnv(hasSession: false)
        e.onAcquire = { id in
            Task {
                try? await Task.sleep(for: .milliseconds(100))
                e.sessions[id] = e.fake
            }
        }
        let session = try await e.commands.runningSession(pixel)
        #expect(session === e.fake)
        #expect(e.acquired == [pixel.id])
    }

    @Test func sessionFailureIsReturnedWhileWaiting() async {
        let e = AIEnv(hasSession: false)
        let denied = DeviceError(code: .INJECT_PERMISSION_DENIED, message: "没有注入权限")
        e.onAcquire = { e.states[$0] = .failed(denied) }
        let start = ContinuousClock.now
        let error = await asyncCode { _ = try await e.commands.runningSession(pixel) }
        #expect(error == denied)
        #expect(ContinuousClock.now - start < .milliseconds(300))
    }

    @Test func sessionWaitTimesOut() async {
        let e = AIEnv(hasSession: false)
        let error = await asyncCode { _ = try await e.commands.runningSession(pixel) }
        #expect(error?.code == .TIMEOUT && error?.message.contains("等待投屏启动") == true)
    }

    @Test func lockedDeviceIsNotStarted() async {
        let e = AIEnv(hasSession: false)
        e.locks.setLocked(pixel.id, true)
        let error = await asyncCode { _ = try await e.commands.runningSession(pixel) }
        #expect(error?.code == .UNSUPPORTED && error?.message == "投屏未运行")
        #expect(error?.suggestion == "请在 Tandem 中打开该设备")
        #expect(e.acquired.isEmpty)
    }

    // MARK: 截图

    @Test func screenshotPrefersLatestFrame() async throws {
        let e = AIEnv()
        await e.fake.pushFrames(count: 1, size: CGSize(width: 64, height: 48), fps: 30)
        let (output, source) = try await e.commands.screenshot(pixel, hq: false)
        #expect(output.mimeType == "image/jpeg" && source == "投屏帧")
        #expect(output.width == 1280 && output.height == 960)
    }

    @Test func screenshotWithoutFrameUsesScreencap() async throws {
        let e = AIEnv(actions: FakeActions(result: .success(AIEnv.png(width: 1080, height: 2400))))
        let (output, source) = try await e.commands.screenshot(pixel, hq: false)
        #expect(output.mimeType == "image/png" && source == "screencap")
    }

    @Test func screenshotHQUsesScreencap() async throws {
        let e = AIEnv(actions: FakeActions(result: .success(AIEnv.png(width: 1080, height: 2400))))
        await e.fake.pushFrames(count: 1, size: CGSize(width: 64, height: 48), fps: 30)
        let (output, source) = try await e.commands.screenshot(pixel, hq: true)
        #expect(output.mimeType == "image/png" && source == "screencap")
        #expect(output.width == 576 && output.height == 1280)
    }

    @Test func screenshotWithoutActionsIsDeviceNotFound() async {
        let e = AIEnv(hasSession: false)
        e.actions = [:]
        let error = await asyncCode { _ = try await e.commands.screenshot(pixel, hq: false) }
        #expect(error?.code == .DEVICE_NOT_FOUND)
    }

    @Test func perceptionSuccessIsNotLogged() async throws {
        let e = AIEnv(actions: FakeActions(result: .success(AIEnv.png(width: 1080, height: 2400))))
        _ = try await e.commands.screenshot(pixel, hq: true)
        #expect(e.log.entries.isEmpty)
        e.actions[pixel.id] = FakeActions(result: .failure(DeviceError(code: .TIMEOUT, message: "截图超时")))
        let error = await asyncCode { _ = try await e.commands.screenshot(pixel, hq: true) }
        #expect(error?.message == "截图超时")
        #expect(e.log.entries.count == 1)
        #expect(e.log.entries.first?.source == .ai && e.log.entries.first?.title == "screenshot")
        #expect(e.log.entries.first?.failure == "截图超时")
        #expect(e.runner.lastError == nil)
    }

    // MARK: UI 树

    @Test func uiTreeIsCached() async throws {
        let tree = AIEnv.tree([AIEnv.element(0, text: "登录", id: "app:id/login")])
        let e = AIEnv(actions: FakeActions(treeProvider: { tree }))
        #expect(e.commands.cachedTree(pixel.id) == nil)
        let text = try await e.commands.uiTree(pixel, all: false)
        #expect(text.contains("\"登录\"") && text.contains("id=login"))
        #expect(e.commands.cachedTree(pixel.id) == tree)
    }

    @Test func waitForReturnsWhenElementAppears() async throws {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let e = AIEnv(actions: FakeActions(treeProvider: {
            let n = reads.withLock { count -> Int in
                count += 1
                return count
            }
            return AIEnv.tree(n < 2 ? [] : [AIEnv.element(3, text: "登录")])
        }))
        let line = try await e.commands.waitFor(pixel, text: "登录", id: nil, timeout: .seconds(2))
        #expect(line.hasPrefix("[3]") && line.contains("登录"))
        #expect(reads.withLock { $0 } == 2)
        #expect(e.commands.cachedTree(pixel.id) != nil)
    }

    @Test func waitForKeepsGoingAfterReadFailure() async throws {
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let e = AIEnv(actions: FakeActions(treeProvider: {
            let n = reads.withLock { count -> Int in
                count += 1
                return count
            }
            if n == 1 { throw DeviceError(code: .TIMEOUT, message: "读取界面超时") }
            return AIEnv.tree([AIEnv.element(1, id: "app:id/ok")])
        }))
        let line = try await e.commands.waitFor(pixel, text: nil, id: "ok", timeout: .seconds(2))
        #expect(line.hasPrefix("[1]"))
    }

    @Test func waitForIgnoresHiddenElements() async {
        let hidden = AIEnv.element(1, text: "登录", bounds: .zero)
        let e = AIEnv(actions: FakeActions(treeProvider: { AIEnv.tree([hidden]) }))
        let error = await asyncCode { _ = try await e.commands.waitFor(pixel, text: "登录", id: nil, timeout: .milliseconds(300)) }
        #expect(error?.code == .TIMEOUT && error?.message.contains("等待元素") == true)
        #expect(e.log.entries.first?.title == "wait_for 登录")
    }

    @Test func waitForSkipsHiddenMatchForVisibleOne() async throws {
        let tree = AIEnv.tree([AIEnv.element(1, text: "登录", bounds: .zero), AIEnv.element(2, text: "登录")])
        let e = AIEnv(actions: FakeActions(treeProvider: { tree }))
        let line = try await e.commands.waitFor(pixel, text: "登录", id: nil, timeout: .seconds(1))
        #expect(line.hasPrefix("[2]"))
    }

    // MARK: 剪贴板与其他

    @Test func getClipboardDoesNotTouchMac() async throws {
        let e = AIEnv()
        e.raw.clearContents()
        e.raw.setString("mac", forType: .string)
        e.fake.clipboardResult = .success("device")
        #expect(try await e.commands.getClipboard(pixel) == "device")
        #expect(e.raw.string(forType: .string) == "mac")
        #expect(e.clipboard.preview[pixel.id] == nil)
        #expect(e.clipboard.history[pixel.id]?.first?.text == "device")
    }

    @Test func getClipboardTimeoutSuggestsEmptyOrNonText() async {
        let e = AIEnv()
        e.fake.clipboardResult = .failure(DeviceError.timeout("读取剪切板"))
        let error = await asyncCode { _ = try await e.commands.getClipboard(pixel) }
        #expect(error?.code == .TIMEOUT && error?.suggestion == "设备剪贴板可能为空或不是文本")
    }

    @Test func listDevicesDescribesEachDevice() {
        let wifi = DeviceInfo(
            serial: "10.0.0.2:5555", platform: .android, name: "Galaxy", state: .unauthorized, connection: .wifi,
            hardwareSerial: "HW2")
        let e = AIEnv(devices: [pixel, wifi])
        e.locks.setLocked("HW2", true)
        #expect(e.commands.listDevices() == """
            - Pixel (id=HW1, android, USB, 已连接, 投屏中, AI 可操作)
            - Galaxy (id=HW2, android, Wi-Fi, 未授权, 未投屏, 禁止 AI)
            """)
    }

    @Test func listDevicesAppendsToolsLine() {
        let e = AIEnv()
        #expect(e.commands.listDevices(tools: { _ in ["screenshot", "tap"] }) == """
            - Pixel (id=HW1, android, USB, 已连接, 投屏中, AI 可操作)
              工具：screenshot, tap
            """)
    }

    @Test func touchUpdatesPresence() async throws {
        let e = AIEnv()
        #expect(e.presence.lastUsed[pixel.id] == nil)
        _ = try await e.commands.uiTree(pixel, all: true)
        #expect(e.presence.lastUsed[pixel.id] != nil)
    }
}
