import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct AICommandsPhysicalTests {
    @Test func firstUSBScreenshotAcquiresManagedSession() async throws {
        var device = AIEnv.pixel
        device.platform = .ios
        let env = AIEnv(devices: [device], hasSession: false)
        await env.fake.pushFrames(count: 1, size: CGSize(width: 120, height: 260), fps: 30)
        env.onAcquire = { id in env.sessions[id] = env.fake }

        let (image, source) = try await env.commands.screenshot(device, hq: false)

        #expect(env.acquired == [device.id])
        #expect(source == "投屏帧")
        #expect(image.mimeType == "image/jpeg")
    }

    @Test func failedUSBAcquisitionDoesNotUseUnmanagedScreenshot() async {
        var device = AIEnv.pixel
        device.platform = .ios
        let env = AIEnv(devices: [device], actions: FakeActions(result: .success(AIEnv.png(width: 120, height: 260))), hasSession: false)
        env.onAcquire = { id in
            env.states[id] = .failed(.init(code: .CONNECTION_FAILED, message: "USB test disconnected"))
        }

        do {
            _ = try await env.commands.screenshot(device, hq: false)
            Issue.record("A failed managed USB session must not open a hidden screenshot session")
        } catch {
            #expect((error as? DeviceError)?.code == .CONNECTION_FAILED)
        }
        #expect(env.acquired == [device.id])
    }

    @Test func taskOwnedStartingSessionDoesNotAcquireMCPOwnership() async throws {
        let env = AIEnv(hasSession: false)
        let id = AIEnv.pixel.id
        env.wanted = [id]
        env.states[id] = .connecting
        let ready = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(30))
            env.sessions[id] = env.fake
        }
        _ = try await AIExecutionContext.$isPhoneAgent.withValue(true) {
            try await env.commands.runningSession(AIEnv.pixel)
        }
        try await ready.value
        #expect(env.acquired.isEmpty)
        #expect(env.restarted.isEmpty)
    }

    @Test func externalMCPRetainsSessionAfterAgentFinishes() async throws {
        let env = AIEnv()
        env.agentOwned = [AIEnv.pixel.id]
        _ = try await env.commands.runningSession(AIEnv.pixel)
        #expect(env.acquired == [AIEnv.pixel.id])
    }

    @Test(arguments: ["Hello Test123", "中文输入 😀", "第一行\nSecond line"])
    func usbTextUsesNativeInputInsteadOfPublicClipboard(_ text: String) async throws {
        var device = AIEnv.pixel
        device.platform = .ios
        let env = AIEnv(devices: [device])
        _ = try await env.commands.typeText(device, text, submit: false)
        #expect(env.fake.sentActions == [.text(text)])
        #expect(env.fake.setClipboardCalls.isEmpty)
        #expect(env.log.entries.allSatisfy { !$0.title.contains(text) })
    }

    @Test func usbTextSubmitsOnlyWhenExplicitlyRequested() async throws {
        var device = AIEnv.pixel
        device.platform = .ios
        let env = AIEnv(devices: [device])
        _ = try await env.commands.typeText(device, "中文 Test", submit: true)
        #expect(env.fake.sentActions == [.text("中文 Test"), .key(.enter)])
        #expect(env.fake.setClipboardCalls.isEmpty)
    }

    @Test func nativeTextFailureDoesNotTryAnotherInputRoute() async {
        var device = AIEnv.pixel
        device.platform = .ios
        let env = AIEnv(devices: [device])
        env.fake.checkedSendError = .connectionFailed("输入结果未知")
        do {
            _ = try await env.commands.typeText(device, "不要重复", submit: true)
            Issue.record("Expected input failure")
        } catch {
            #expect((error as? DeviceError)?.code == .CONNECTION_FAILED)
        }
        #expect(env.fake.sentActions.isEmpty)
        #expect(env.fake.setClipboardCalls.isEmpty)
    }
}
