import DeviceCore
import Foundation
import Testing
@testable import Tandem

/// Safe physical-device validation: text goes into Settings search, never a chat.
@MainActor @Suite struct PhoneAgentTextLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TANDEM_LIVE_PHONE_AGENT_TEXT"] == "1"))
    func entersUnicodeInSettingsSearch() async throws {
        let defaults = UserDefaults(suiteName: "TandemTextLive-\(UUID().uuidString)")!
        let model = AppModel(defaults: defaults)
        let frameDirectory = ProcessInfo.processInfo.environment["TANDEM_LIVE_TEXT_FRAMES"].map { URL(fileURLWithPath: $0) }
        let services = AppServices(model: model, defaults: defaults, phonePlanner: RecordingPhonePlanner(directory: frameDirectory))
        await model.start()
        do {
            let udid = ProcessInfo.processInfo.environment["TANDEM_LIVE_UDID"]
            for _ in 0..<150 {
                if model.devices.contains(where: { $0.platform == .ios && $0.connection == .usb && $0.state == .connected && (udid == nil || $0.id == udid) }) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let candidate = model.devices.first(where: {
                $0.platform == .ios && $0.connection == .usb && $0.state == .connected && (udid == nil || $0.id == udid)
            })
            let device = try #require(candidate)
            #expect(device.capabilities.contains(.text))
            await model.workspaceAppeared()
            await model.select(device.id)
            // Leave any private app before sending the first screen to a model.
            let home = try await services.registry.call("press_key", arguments: ["device": .string(device.id), "key": "home"])
            #expect(!home.isError)
            try await Task.sleep(for: .seconds(1))
            services.agentSettings.provider = .codex
            services.agentSettings.codexModel = ProcessInfo.processInfo.environment["TANDEM_LIVE_PLANNER_MODEL"] ?? "gpt-6.1-sol"
            let query = ProcessInfo.processInfo.environment["TANDEM_LIVE_TEXT_QUERY"] ?? "Tandem中文A1😀"
            let direct = ProcessInfo.processInfo.environment["TANDEM_LIVE_DIRECT_TEXT"] == "1"
            let goal = direct
                ? "打开系统设置，进入设置的搜索界面并点击搜索框使其获得焦点。不要输入任何文字，不修改任何设置。"
                : "打开系统设置，把设置搜索框中的关键词改为「\(query)」。确认输入框完整包含这些文字后停在搜索界面，不点击搜索结果，不更改任何设置。"
            services.phoneAgent.start(
                goal: goal, deviceID: device.id)
            await services.phoneAgent.waitUntilFinished()
            let result = try #require(services.phoneAgent.runs[device.id])
            print("USB Unicode agent: \(result.status.rawValue), \(result.steps.count) steps, \(result.message)")
            for step in result.steps {
                print("  \(step.number). \(step.summary) / \(step.tool): \(step.result)")
                if let planning = step.planningSeconds, let execution = step.executionSeconds {
                    print(String(format: "     model=%.3fs, device=%.3fs", planning, execution))
                }
            }
            if direct {
                try #require(result.status == .completed, "准备搜索输入框失败，不继续输入")
                let started = ContinuousClock.now
                let textResult = try await services.ai.typeText(device, query, submit: false, replace: true)
                print("Direct native replacement: \(ContinuousClock.now - started), \(textResult)")
                if let frameDirectory {
                    for index in 1...4 {
                        try await Task.sleep(for: .milliseconds(400))
                        let (image, _) = try await services.ai.screenshot(device, hq: false)
                        try image.data.write(to: frameDirectory.appendingPathComponent("after-\(index).jpg"), options: .atomic)
                    }
                }
            }
            if let output = ProcessInfo.processInfo.environment["TANDEM_LIVE_TEXT_IMAGE"] {
                let (image, _) = try await services.ai.screenshot(device, hq: false)
                try image.data.write(to: URL(fileURLWithPath: output), options: .atomic)
            }
            await services.shutdown()
            #expect(result.status == .completed, "\(result.message)")
            if !direct { #expect(result.steps.contains(where: { ["type_text", "fill_text"].contains($0.tool) })) }
        } catch {
            await services.shutdown()
            throw error
        }
    }
}

/// Optional local evidence for this safe Settings-only hardware test.
private struct RecordingPhonePlanner: PhoneAgentPlanning {
    let directory: URL?
    func decide(_ input: PhoneAgentInput, configuration: PhoneAgentConfiguration) async throws -> PhoneAgentDecision {
        if let directory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let suffix = input.mimeType == "image/png" ? "png" : "jpg"
            try input.image.write(to: directory.appendingPathComponent("step-\(input.step).\(suffix)"), options: .atomic)
        }
        return try await PhoneAgentPlanner().decide(input, configuration: configuration)
    }
}
