import DeviceCore
import Foundation
import Testing
@testable import Tandem

/// Explicit opt-in only: this test sends screenshots to the logged-in model
/// and navigates the connected phone to a read-only Settings page.
@MainActor @Suite struct PhoneAgentLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TANDEM_LIVE_PHONE_AGENT"] == "1"))
    func opensBatterySettingsOnUSBPhone() async throws {
        let defaults = UserDefaults(suiteName: "TandemAgentLive-\(UUID().uuidString)")!
        let model = AppModel(defaults: defaults)
        let services = AppServices(model: model, defaults: defaults)
        await model.start()
        let udid = ProcessInfo.processInfo.environment["TANDEM_LIVE_UDID"]
        for _ in 0..<150 {
            if model.devices.contains(where: { $0.platform == .ios && $0.connection == .usb && $0.state == .connected && (udid == nil || $0.id == udid) }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let candidate = model.devices.first(where: {
            $0.platform == .ios && $0.connection == .usb && $0.state == .connected && (udid == nil || $0.id == udid)
        })
        let device = try #require(candidate)
        services.agentSettings.provider = .codex
        services.agentSettings.codexModel = "gpt-6.1-sol"
        services.phoneAgent.start(
            goal: "打开系统设置，进入电池页面，停在该页面。不要更改任何设置。", deviceID: device.id)
        await services.phoneAgent.waitUntilFinished()
        let result = try #require(services.phoneAgent.runs[device.id])
        print("Phone agent live: \(result.status.rawValue), \(result.steps.count) steps, \(result.message)")
        for step in result.steps { print("  \(step.number). \(step.summary) / \(step.tool): \(step.result)") }
        await services.shutdown()
        #expect(result.status == .completed, "\(result.message)")
    }
}
