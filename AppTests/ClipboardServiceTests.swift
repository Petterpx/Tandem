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
        // 失败后恢复：首次成功仍只记基准
        bad.clipboardResult = .success("q")
        await env.service.pollDevices(sessions: ["bad": bad])
        #expect(env.mac.string() == nil)
    }
}
