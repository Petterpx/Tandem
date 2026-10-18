import AppKit
import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct ClipboardServiceTests {
    private struct Env {
        let service: ClipboardService
        let mac: MacPasteboard
        let raw: NSPasteboard
        let defaults: UserDefaults
    }

    private func make(defaults: UserDefaults? = nil) -> Env {
        let raw = NSPasteboard(name: .init(UUID().uuidString))
        let mac = MacPasteboard(raw)
        let d = defaults ?? UserDefaults(suiteName: UUID().uuidString)!
        return Env(service: ClipboardService(pasteboard: mac, defaults: d), mac: mac, raw: raw, defaults: d)
    }

    private func external(_ env: Env, _ text: String) {
        env.raw.clearContents()
        env.raw.setString(text, forType: .string)
    }

    @Test func writeSourcePrefersInput() {
        #expect(ClipboardService.writeSource(input: "abc", macText: "m") == .input("abc"))
        #expect(ClipboardService.writeSource(input: "", macText: "m") == .macClipboard("m"))
        #expect(ClipboardService.writeSource(input: "", macText: nil) == .unavailable)
    }

    @Test func readUpdatesPreviewMacAndHistory() async throws {
        let env = make()
        let fake = FakeDeviceSession()
        fake.clipboardResult = .success("hi")
        let text = try await env.service.read("a", session: fake)
        #expect(text == "hi")
        #expect(env.service.preview["a"] == "hi")
        #expect(env.mac.string() == "hi")
        #expect(env.service.history["a"]?.first?.direction == .read)
    }

    @Test func historyCappedAtTen() async throws {
        let env = make()
        let fake = FakeDeviceSession()
        for i in 0..<11 { try await env.service.write("a", text: "t\(i)", paste: false, session: fake) }
        let h = try #require(env.service.history["a"])
        #expect(h.count == 10)
        #expect(h.first?.text == "t10" && h.first?.direction == .write)
    }

    @Test func devicePushIgnoredWhenSyncOff() {
        let env = make()
        env.service.deviceClipboardChanged("a", text: "x")
        #expect(env.mac.string() == nil)
        #expect(env.service.history["a"] == nil)
    }

    @Test func devicePushGoesToMacWhenSyncOn() {
        let env = make()
        env.service.setSyncEnabled("a", true)
        env.service.deviceClipboardChanged("a", text: "x")
        #expect(env.mac.string() == "x")
        #expect(env.service.history["a"]?.first?.direction == .sync)
    }

    @Test func macChangePushedToSyncedDevicesOnly() async {
        let env = make()
        let a = FakeDeviceSession(), b = FakeDeviceSession()
        env.service.setSyncEnabled("a", true)
        external(env, "hello")
        await env.service.pollMac(sessions: ["a": a, "b": b])
        #expect(a.setClipboardCalls.map(\.text) == ["hello"])
        #expect(a.setClipboardCalls.first?.paste == false)
        #expect(b.setClipboardCalls.isEmpty)
    }

    @Test func ownMacWriteIsNotPushedToAnyDevice() async {
        let env = make()
        let a = FakeDeviceSession(), b = FakeDeviceSession()
        env.service.setSyncEnabled("a", true)
        env.service.setSyncEnabled("b", true)
        env.service.deviceClipboardChanged("a", text: "x")
        #expect(env.mac.string() == "x")
        await env.service.pollMac(sessions: ["a": a, "b": b])
        #expect(a.setClipboardCalls.isEmpty && b.setClipboardCalls.isEmpty)
    }

    @Test func sameTextIsNotResent() async {
        let env = make()
        let a = FakeDeviceSession()
        env.service.setSyncEnabled("a", true)
        external(env, "y")
        await env.service.pollMac(sessions: ["a": a])
        external(env, "y")
        await env.service.pollMac(sessions: ["a": a])
        #expect(a.setClipboardCalls.count == 1)
    }

    @Test func syncSettingPersists() {
        let env = make()
        env.service.setSyncEnabled("a", true)
        let again = ClipboardService(pasteboard: env.mac, defaults: env.defaults)
        #expect(again.isSyncEnabled("a"))
        #expect(!again.isSyncEnabled("b"))
    }

    @Test func devicePollSeedsBaselineThenSyncsChanges() async {
        let env = make()
        let a = FakeDeviceSession()
        a.clipboardResult = .success("a")
        env.service.setSyncEnabled("a", true)
        await env.service.pollDevices(sessions: ["a": a])
        #expect(env.mac.string() == nil)
        #expect(env.service.history["a"] == nil)
        a.clipboardResult = .success("b")
        await env.service.pollDevices(sessions: ["a": a])
        #expect(env.mac.string() == "b")
        #expect(env.service.history["a"]?.first?.direction == .sync)
        // 再轮询一次相同内容不会重复写 Mac，pollMac 也不回推
        let count = env.mac.changeCount
        await env.service.pollDevices(sessions: ["a": a])
        await env.service.pollMac(sessions: ["a": a])
        #expect(env.mac.changeCount == count && a.setClipboardCalls.isEmpty)
        // 关闭再开启后重新取基准
        env.service.setSyncEnabled("a", false)
        env.service.setSyncEnabled("a", true)
        a.clipboardResult = .success("c")
        await env.service.pollDevices(sessions: ["a": a])
        #expect(env.mac.string() == "b")
    }

    @Test func polledEchoOfMacWriteIsNotSentBack() async {
        let env = make()
        let a = FakeDeviceSession()
        a.clipboardResult = .success("a0")
        env.service.setSyncEnabled("a", true)
        await env.service.pollDevices(sessions: ["a": a])  // 基准
        external(env, "y")
        await env.service.pollMac(sessions: ["a": a])
        #expect(a.setClipboardCalls.map(\.text) == ["y"])
        a.clipboardResult = .success("y")
        let count = env.mac.changeCount
        let syncs = env.service.history["a"]?.filter { $0.direction == .sync }.count
        await env.service.pollDevices(sessions: ["a": a])
        #expect(env.mac.changeCount == count)
        #expect(env.service.history["a"]?.filter { $0.direction == .sync }.count == syncs)
    }

    @Test func truncatedEchoOfLargeTextIsNotSentBack() async {
        let env = make()
        let a = FakeDeviceSession()
        a.clipboardResult = .success("a0")
        env.service.setSyncEnabled("a", true)
        await env.service.pollDevices(sessions: ["a": a])
        let big = String(repeating: "字", count: 100_000)  // 300 KB UTF-8，超过上限
        external(env, big)
        await env.service.pollMac(sessions: ["a": a])
        #expect(a.setClipboardCalls.map(\.text) == [big])
        a.clipboardResult = .success(String(big.prefix(80_000)))
        let count = env.mac.changeCount
        let syncs = env.service.history["a"]?.filter { $0.direction == .sync }.count
        await env.service.pollDevices(sessions: ["a": a])
        #expect(env.mac.changeCount == count)
        #expect(env.service.history["a"]?.filter { $0.direction == .sync }.count == syncs)
    }

    @Test func failedPushDoesNotLetOldDeviceTextOverwriteMac() async {
        struct Boom: Error {}
        let env = make()
        let a = FakeDeviceSession()
        a.clipboardResult = .success("a0")
        env.service.setSyncEnabled("a", true)
        await env.service.pollDevices(sessions: ["a": a])  // 基准
        a.setClipboardError = Boom()
        external(env, "m")
        await env.service.pollMac(sessions: ["a": a])
        await env.service.pollDevices(sessions: ["a": a])
        #expect(env.mac.string() == "m")
        #expect(env.service.history["a"] == nil)
    }

    @Test func pollIgnoresDisabledDevicesAndErrors() async {
        struct Boom: Error {}
        let env = make()
        let off = FakeDeviceSession(), bad = FakeDeviceSession()
        off.clipboardResult = .success("z")
        bad.clipboardResult = .failure(Boom())
        env.service.setSyncEnabled("bad", true)
        await env.service.pollDevices(sessions: ["off": off, "bad": bad])
        #expect(env.mac.string() == nil)
        #expect(env.service.history.isEmpty)
    }

    /// 等待条件成立（最多 timeout），返回最终结果。
    private func eventually(_ timeout: Duration = .seconds(2), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    @Test func failedFirstPollStillCountsAsBaseline() async {
        struct Boom: Error {}
        let env = make()
        let a = FakeDeviceSession()
        // 手机剪贴板为空或是图片：scrcpy 不应答，读取超时
        a.clipboardResult = .failure(Boom())
        env.service.setSyncEnabled("a", true)
        await env.service.pollDevices(sessions: ["a": a])
        #expect(env.mac.string() == nil)
        // 之后第一次复制的文字要同步到 Mac
        a.clipboardResult = .success("x")
        await env.service.pollDevices(sessions: ["a": a])
        #expect(env.mac.string() == "x")
        #expect(env.service.history["a"]?.first?.direction == .sync)
    }

    @Test func slowDeviceReadDoesNotDelayOtherDevices() async {
        let env = make()
        let a = FakeDeviceSession(), b = FakeDeviceSession()
        a.clipboardResult = .success("a0")
        b.clipboardResult = .success("b0")
        env.service.setSyncEnabled("a", true)
        env.service.setSyncEnabled("b", true)
        await env.service.pollDevices(sessions: ["a": a, "b": b])  // 基准
        a.holdClipboardReads()
        b.clipboardResult = .success("x")
        let poll = Task { await env.service.pollDevices(sessions: ["a": a, "b": b]) }
        // a 的读取还挂着，b 的变化在同一轮里就到了 Mac
        #expect(await eventually { env.mac.string() == "x" })
        #expect(a.heldReadCount == 1)
        a.releaseClipboardReads()
        await poll.value
        #expect(env.mac.string() == "x")
    }

    @Test func syncLoopKeepsPushingWhileADeviceReadHangs() async {
        let env = make()
        let a = FakeDeviceSession(), b = FakeDeviceSession()
        env.service.setSyncEnabled("a", true)
        env.service.setSyncEnabled("b", true)
        a.holdClipboardReads()
        let loop = Task { await env.service.runSyncLoop { ["a": a, "b": b] } }
        #expect(await eventually { a.heldReadCount == 1 })
        external(env, "m")
        // a 的读取一直没有返回，Mac → 设备仍按 0.5 秒节奏推送
        #expect(await eventually { b.setClipboardCalls.map(\.text) == ["m"] && a.setClipboardCalls.map(\.text) == ["m"] })
        // 同一台设备的读取不重叠
        #expect(a.getClipboardCallCount == 1)
        #expect(await eventually { b.getClipboardCallCount >= 2 })
        a.releaseClipboardReads()
        loop.cancel()
        await loop.value
    }

    @Test func readInFlightDuringPushIsDiscarded() async {
        let env = make()
        let a = FakeDeviceSession()
        a.clipboardResult = .success("a0")
        env.service.setSyncEnabled("a", true)
        await env.service.pollDevices(sessions: ["a": a])  // 基准
        a.holdClipboardReads()
        let poll = Task { await env.service.pollDevices(sessions: ["a": a]) }
        #expect(await eventually { a.heldReadCount == 1 })
        external(env, "m")
        await env.service.pollMac(sessions: ["a": a])
        #expect(a.setClipboardCalls.map(\.text) == ["m"])
        // 推送前发出的读取带回旧内容，不能覆盖 Mac
        a.releaseClipboardReads()
        await poll.value
        #expect(env.mac.string() == "m")
        #expect(env.service.history["a"]?.map(\.text) == ["m"])
    }
}
