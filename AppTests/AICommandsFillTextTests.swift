import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor @Suite struct AICommandsFillTextTests {
    private func phoneEnvironment(
        pastePermission: @escaping @Sendable (VideoFrame) async -> NormalizedPoint? = { await PastePermissionResolver.resolve($0) },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }) -> (AIEnv, DeviceInfo) {
        let phone = DeviceInfo(serial: "fill-phone", platform: .ios, name: "iPhone", state: .connected,
                               connection: .usb, capabilities: [.touch, .text, .screenshot])
        let env = AIEnv(devices: [phone], pastePermission: pastePermission, sleep: sleep)
        env.sessions[phone.id] = env.fake
        env.states[phone.id] = .running(width: 586, height: 1280)
        return (env, phone)
    }


    @Test func replacingUsesOneNativeReplacementWithoutAppendOrSubmit() async throws {
        let (env, phone) = phoneEnvironment()
        _ = try await env.commands.fillText(phone, .point(x: 180, y: 1200), text: "new query", replace: true)
        #expect(env.fake.replacedTexts == ["new query"])
        #expect(env.fake.sentActions.count == 2)
        #expect(env.fake.setClipboardCalls.isEmpty)
        _ = try await env.commands.typeText(phone, "完整替换", submit: false, replace: true)
        #expect(env.fake.replacedTexts == ["new query", "完整替换"])
        #expect(env.fake.sentActions.count == 2)
    }

    @Test func nulAndUnsupportedReplacementAreRejectedBeforeFocus() async {
        let (env, phone) = phoneEnvironment()
        do {
            _ = try await env.commands.fillText(phone, .point(x: 180, y: 1200), text: "a\0b", replace: true)
            Issue.record("Expected NUL rejection")
        } catch { #expect((error as? DeviceError)?.code == .INVALID_ARGUMENT) }
        #expect(env.fake.sentActions.isEmpty)
        let android = AIEnv(sleep: { _ in })
        do {
            _ = try await android.commands.fillText(AIEnv.pixel, .point(x: 10, y: 20), text: "x", replace: true)
            Issue.record("Expected unsupported replacement")
        } catch { #expect((error as? DeviceError)?.code == .UNSUPPORTED) }
        #expect(android.fake.sentActions.isEmpty)
    }

    @Test(arguments: [false, true])
    func recentPasteClicksExactlyOnceOnlyWhenResolverFindsDialog(found: Bool) async throws {
        let probe = PasteResolverProbe(found: found)
        let (env, phone) = phoneEnvironment(pastePermission: { _ in await probe.resolve() })
        await env.fake.pushFrames(count: 1, size: CGSize(width: 586, height: 1280), fps: 30)
        let result = try await env.commands.typeText(phone, "complete text", submit: false)
        #expect(env.fake.sentActions.first == .text("complete text"))
        #expect(env.fake.sentActions.count == (found ? 3 : 1))
        #expect(await probe.count == (found ? 1 : 3))
        #expect(result.contains("已允许系统粘贴") == found)
        #expect(!env.fake.sentActions.contains(.key(.enter)))
        if found {
            #expect(env.fake.sentActions[1] == .touch(.down, NormalizedPoint(x: 0.5, y: 0.6), pointer: .ai))
            #expect(env.fake.sentActions[2] == .touch(.up, NormalizedPoint(x: 0.5, y: 0.6), pointer: .ai))
        }
    }

    @Test func cancelledPermissionWaitDoesNotClick() async {
        let probe = PasteResolverProbe(found: true)
        let (env, phone) = phoneEnvironment(pastePermission: { _ in await probe.resolve() }, sleep: { duration in
            if duration == .milliseconds(200) { throw CancellationError() }
        })
        await env.fake.pushFrames(count: 1, size: CGSize(width: 586, height: 1280), fps: 30)
        do {
            _ = try await env.commands.typeText(phone, "whole text", submit: false)
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
        #expect(env.fake.sentActions == [.text("whole text")])
        #expect(await probe.count == 0)
    }

    @Test func permissionTouchFailurePropagatesWithoutReplay() async {
        let fake = FakeDeviceSession()
        let probe = PasteResolverProbe(found: true)
        let (env, phone) = phoneEnvironment(pastePermission: { _ in
            let point = await probe.resolve()
            fake.checkedSendError = DeviceError.connectionFailed("permission touch failed")
            return point
        })
        env.sessions[phone.id] = fake
        await fake.pushFrames(count: 1, size: CGSize(width: 586, height: 1280), fps: 30)
        do {
            _ = try await env.commands.typeText(phone, "whole text", submit: false)
            Issue.record("Expected touch failure")
        } catch { #expect((error as? DeviceError)?.code == .CONNECTION_FAILED) }
        #expect(fake.sentActions == [.text("whole text")])
        #expect(await probe.count == 1)
    }

    @Test func nativeFillFocusesThenInsertsWholeStringWithoutSubmitting() async throws {
        let (env, phone) = phoneEnvironment()
        let value = "中文 CLI 🚀"
        _ = try await env.commands.fillText(phone, .point(x: 180, y: 1200), text: value)
        let actions = env.fake.sentActions
        #expect(actions.count == 3)
        guard case .touch(.down, _, .ai) = actions[0], case .touch(.up, _, .ai) = actions[1] else {
            Issue.record("输入前应先完成点按")
            return
        }
        #expect(actions.last == .text(value))
        #expect(!actions.contains(.key(.enter)))
        #expect(env.fake.setClipboardCalls.isEmpty)
        #expect(env.log.entries.count == 1)
        #expect(env.log.entries.first?.title.contains(value) == false)
    }

    @Test func unicodeFillOnAndroidKeepsClipboardPath() async throws {
        let env = AIEnv(sleep: { _ in })
        env.states[AIEnv.pixel.id] = .running(width: 1080, height: 2400)
        _ = try await env.commands.fillText(AIEnv.pixel, .point(x: 200, y: 500), text: "你好")
        #expect(env.fake.sentActions.count == 2)
        #expect(env.fake.setClipboardCalls.count == 1)
        #expect(env.fake.setClipboardCalls.first?.text == "你好")
        #expect(env.fake.setClipboardCalls.first?.paste == true)
    }

    @Test func cancellationAfterFocusNeverWritesText() async {
        let (env, phone) = phoneEnvironment(sleep: { duration in
            if duration == .milliseconds(300) { throw CancellationError() }
        })
        do {
            _ = try await env.commands.fillText(phone, .point(x: 180, y: 1200), text: "不要发送")
            Issue.record("Expected cancellation")
        } catch { #expect(error is CancellationError) }
        #expect(env.fake.sentActions.count == 2)
        #expect(env.fake.setClipboardCalls.isEmpty)
    }

    @Test func oversizedNativeTextIsRejectedBeforeFocus() async {
        let (env, phone) = phoneEnvironment()
        do {
            _ = try await env.commands.fillText(phone, .point(x: 180, y: 1200), text: String(repeating: "中", count: 2731))
            Issue.record("Expected UTF-8 size rejection")
        } catch { #expect((error as? DeviceError)?.code == .INVALID_ARGUMENT) }
        #expect(env.fake.sentActions.isEmpty)
    }

    @Test func concurrentFillsDoNotInterleaveFocusAndInput() async throws {
        let (env, phone) = phoneEnvironment()
        env.fake.sendDelay = .milliseconds(5)
        async let first = env.commands.fillText(phone, .point(x: 100, y: 100), text: "first")
        async let second = env.commands.fillText(phone, .point(x: 200, y: 200), text: "second")
        _ = try await (first, second)
        let actions = env.fake.sentActions
        #expect(actions.count == 6)
        guard case .text(let firstText) = actions[2], case .text(let secondText) = actions[5] else {
            Issue.record("每次聚焦与整段输入应在同一设备锁内完成")
            return
        }
        #expect(Set([firstText, secondText]) == ["first", "second"])
        #expect(!actions.contains(.key(.enter)))
    }
}

private actor PasteResolverProbe {
    private(set) var count = 0
    let found: Bool
    init(found: Bool) { self.found = found }
    func resolve() -> NormalizedPoint? {
        count += 1
        return found ? NormalizedPoint(x: 0.5, y: 0.6) : nil
    }
}
