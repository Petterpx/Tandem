import AppKit
import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct AppServicesTests {
    private let dev = DeviceInfo(
        serial: "s1", platform: .android, name: "Pixel", state: .connected, connection: .usb,
        hardwareSerial: "HW1", capabilities: [.screenshot, .record])

    private struct Env {
        let model: AppModel
        let services: AppServices
        let raw: NSPasteboard
    }

    private func make() -> Env {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-\(UUID().uuidString)")
        defaults.set(dir.path, forKey: "recordingDirectory")
        defaults.set(dir.path, forKey: "screenshotDirectory")
        let raw = NSPasteboard(name: .init(UUID().uuidString))
        let model = AppModel(defaults: defaults)
        let services = AppServices(model: model, pasteboard: MacPasteboard(raw), defaults: defaults)
        services.connect(model)
        return Env(model: model, services: services, raw: raw)
    }

    @Test func deviceClipboardHookReachesClipboardService() {
        let e = make()
        e.services.clipboard.setSyncEnabled("HW1", true)
        e.model.onDeviceClipboard?("HW1", "hello")
        #expect(e.raw.string(forType: .string) == "hello")
    }

    @Test func sessionEndedHookAutoStopsRecording() async {
        let e = make()
        e.model.devices = [dev]
        let fake = FakeDeviceSession()
        try? e.services.recording.start("HW1", deviceName: dev.name, session: fake, origin: .workspace)
        #expect(e.services.recording.isRecording("HW1"))
        e.model.onSessionEnded?("HW1", .disconnected)
        // 钩子在新 Task 中收尾，等它写下记录
        for _ in 0..<200 where e.services.log.entries.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(!e.services.recording.isRecording("HW1"))
        #expect(e.services.log.entries.first?.title == "录屏已自动结束（设备已断开）")
    }

    @Test func syncLoopSessionsAreEmptyWithoutRunningSessions() {
        let e = make()
        e.model.sessionStates["HW1"] = .running(width: 1080, height: 2340)
        // 状态是 running 但还没有会话对象：不应出现在同步列表里
        #expect(AppServices.runningSessions(of: e.model).isEmpty)
    }
}
