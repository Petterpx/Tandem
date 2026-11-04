import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct AICommandsSimulatorTests {
    private func environment(sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }) -> (AIEnv, DeviceInfo) {
        var device = AIEnv.pixel
        device.platform = .ios
        device.connection = .simulator
        device.capabilities.remove(.uiTree)
        let env = AIEnv(devices: [device], sleep: sleep)
        env.states[device.id] = .running(width: 1206, height: 2622)
        return (env, device)
    }

    @Test func unsupportedIOSKeyIsRejectedWithoutSending() async {
        let (env, device) = environment()
        do {
            _ = try await env.commands.pressKey(device, .back)
            Issue.record("iOS Back should be unsupported")
        } catch {
            #expect((error as? DeviceError)?.code == .UNSUPPORTED)
        }
        #expect(env.fake.sentActions.isEmpty)
    }

    @Test func inputBackendFailureIsReturnedToMCP() async {
        let (env, device) = environment()
        env.fake.checkedSendError = .init(code: .CONNECTION_FAILED, message: "模拟器控制连接已关闭")
        do {
            _ = try await env.commands.typeText(device, "hello", submit: false)
            Issue.record("Failed input must not report success")
        } catch {
            #expect((error as? DeviceError)?.code == .CONNECTION_FAILED)
        }
        #expect(env.log.entries.first?.failure != nil)
    }

    @Test func textTargetWithoutUITreeHasActionableError() async {
        let (env, device) = environment()
        do {
            _ = try await env.commands.tap(device, .text("Settings"))
            Issue.record("Text target needs UI tree")
        } catch {
            #expect((error as? DeviceError)?.code == .UNSUPPORTED)
            #expect((error as? DeviceError)?.suggestion?.contains("坐标") == true)
        }
        #expect(env.fake.sentActions.isEmpty)
    }

    @Test func cancelledLongPressReleasesItsTouch() async {
        let (env, device) = environment(sleep: { _ in throw CancellationError() })
        do {
            _ = try await env.commands.longPress(device, .point(x: 100, y: 100), durationMs: 500)
            Issue.record("Should cancel")
        } catch { #expect(error is CancellationError) }
        #expect(env.fake.sentActions.count == 2)
        guard case .touch(.up, _, .ai) = env.fake.sentActions.last else {
            Issue.record("Cancelled gesture left a held touch")
            return
        }
    }

    @Test func simulatorListingAndHomeRemainAvailable() async throws {
        let (env, device) = environment()
        #expect(env.commands.listDevices().contains("模拟器"))
        _ = try await env.commands.pressKey(device, .home)
        #expect(env.fake.sentActions == [.key(.home)])
    }

    @Test func alreadyCancelledAIActionDoesNotSendInput() async {
        let (env, device) = environment()
        let task = Task { try await env.commands.pressKey(device, .home) }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled command should not execute")
        } catch { #expect(error is CancellationError) }
        #expect(env.fake.sentActions.isEmpty)
    }
}
