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
        services.connect()
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

    @Test func quitHookLeavesRecordingToShutdown() async {
        let e = make()
        e.model.devices = [dev]
        let fake = FakeDeviceSession()
        try? e.services.recording.start("HW1", deviceName: dev.name, session: fake, origin: .workspace)
        e.model.onSessionEnded?("HW1", .quit)
        // 给钩子可能创建的 Task 足够时间运行：退出由 shutdown 统一收尾，钩子不应抢先摘走录屏
        try? await Task.sleep(for: .milliseconds(200))
        #expect(e.services.recording.isRecording("HW1"))
    }

    @Test func shutdownFinalizesRecordingBeforeReturning() async {
        let e = make()
        e.model.devices = [dev]
        let fake = FakeDeviceSession()
        try? e.services.recording.start("HW1", deviceName: dev.name, session: fake, origin: .workspace)
        await fake.pushFrames(count: 30, size: CGSize(width: 64, height: 48), fps: 30)
        await e.services.shutdown()
        #expect(!e.services.recording.isRecording("HW1"))
        let item = e.services.store.recent.first
        #expect(item?.kind == .recording)
        #expect(item.map { FileManager.default.fileExists(atPath: $0.url.path) } == true)
        let quitEntries = e.services.log.entries.filter { $0.title == "录屏已自动结束（退出）" }
        #expect(quitEntries.count == 1)
        #expect(quitEntries.first?.failure == nil)
    }
}
