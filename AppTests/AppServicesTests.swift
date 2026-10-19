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

    private func pullJob(_ source: ActivitySource, _ state: TransferJob.State) -> TransferJob {
        TransferJob(
            id: UUID(), deviceID: "HW1", kind: .pull(remote: "/sdcard/x.log", to: URL(fileURLWithPath: "/tmp")),
            origin: .workspace, source: source, state: state)
    }

    /// 只有你发起的成功拉取才在 Finder 中选中；AI 的拉取不抢焦点。
    @Test func finderSelectionOnlyForUserPulls() {
        let url = URL(fileURLWithPath: "/tmp/x.log")
        #expect(AppServices.finderSelection(for: pullJob(.user, .done(.pulled(url)))) == url)
        #expect(AppServices.finderSelection(for: pullJob(.ai, .done(.pulled(url)))) == nil)
        #expect(AppServices.finderSelection(for: pullJob(.user, .cancelled)) == nil)
        #expect(AppServices.finderSelection(for: pullJob(.user, .done(.pushed(["/sdcard/x"])))) == nil)
    }

    /// 启动清理：只删 24 小时前的 tandem-drag-* 与 Tandem-paste/* 项，其余不动。
    @Test func sweepRemovesOnlyOldTemporaries() throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("tandem-sweep-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: tmp) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let old = now.addingTimeInterval(-25 * 3600), fresh = now.addingTimeInterval(-3600)
        func make(_ path: String, _ date: Date, directory: Bool = true) throws -> URL {
            let url = tmp.appendingPathComponent(path)
            if directory {
                try fm.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("x".utf8).write(to: url)
            }
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
            return url
        }
        let oldDrag = try make("tandem-drag-old", old)
        let freshDrag = try make("tandem-drag-new", fresh)
        let oldPaste = try make("Tandem-paste/a", old)
        let oldPasteFile = try make("Tandem-paste/b.png", old, directory: false)
        let freshPaste = try make("Tandem-paste/c", fresh)
        let unrelated = try make("other-old", old)
        AppServices.sweepTemporaries(in: tmp, now: now)
        #expect(!fm.fileExists(atPath: oldDrag.path))
        #expect(!fm.fileExists(atPath: oldPaste.path))
        #expect(!fm.fileExists(atPath: oldPasteFile.path))
        #expect(fm.fileExists(atPath: freshDrag.path))
        #expect(fm.fileExists(atPath: freshPaste.path))
        #expect(fm.fileExists(atPath: unrelated.path))
        #expect(fm.fileExists(atPath: tmp.appendingPathComponent("Tandem-paste").path))
    }

    @Test func allowAIShellControlsShellTool() {
        let e = make()
        #expect(e.services.registry.descriptors(for: []).map(\.name).contains("shell"))
        e.services.setAllowAIShell(false)
        #expect(!e.services.quickStore.allowAIShell)
        #expect(!e.services.registry.descriptors(for: []).map(\.name).contains("shell"))
        e.services.setAllowAIShell(true)
        #expect(e.services.registry.descriptors(for: []).map(\.name).contains("shell"))
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

    @Test func sessionLookupIsNilUnlessRunning() {
        let fake = FakeDeviceSession()
        #expect(AppServices.runningOnly(.running(width: 1, height: 2), fake) != nil)
        #expect(AppServices.runningOnly(.disconnected, fake) == nil)
        #expect(AppServices.runningOnly(.idle, fake) == nil)
        #expect(AppServices.runningOnly(nil, fake) == nil)
    }

    @Test func idleLoopReleasesExpiredAIDevices() async {
        let e = make()
        await e.model.aiAcquire("HW1")
        await e.model.aiAcquire("HW2")
        // HW1 从未被 AI 调用过，视为已空闲；HW2 刚用过
        e.services.presence.touch("HW2")
        let loop = Task { await e.services.runAIIdleLoop(interval: .milliseconds(20)) }
        defer { loop.cancel() }
        for _ in 0..<200 where e.model.mirrors.ai.contains("HW1") {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(e.model.mirrors.ai == ["HW2"])
    }

    @Test func toggleRecordingWithoutRunningSessionFailsCleanly() async {
        let e = make()
        e.model.devices = [dev]
        e.model.sessionStates["HW1"] = .disconnected
        await e.services.commands.toggleRecording("HW1", origin: .workspace)
        #expect(!e.services.recording.isRecording("HW1"))
        #expect(e.services.runner.lastError?.message == "投屏未运行，无法录屏")
    }

    /// 设备列表钩子：有传输的设备不再是 connected 时，交给 TransferQueue 按断开处理。
    /// 全程不挂起，队列来不及开始执行（不会碰真实 adb）。
    @Test func devicesChangedHookCancelsTransfersOfGoneDevice() {
        let e = make()
        e.model.devices = [dev]
        e.services.transfers.enqueue(
            "HW1", .pull(remote: "/sdcard/x.log", to: FileManager.default.temporaryDirectory), origin: .workspace)
        e.model.onDevicesChanged?([dev])
        #expect(e.services.transfers.jobs("HW1").count == 1)
        var offline = dev
        offline.state = .offline
        e.model.onDevicesChanged?([offline])
        #expect(e.services.transfers.jobs("HW1").isEmpty)
    }

    @Test func lockingReleasesDeviceFromAI() async {
        let e = make()
        e.model.devices = [dev]
        await e.model.aiAcquire("HW1")
        await e.services.setAILocked("HW1", true)
        #expect(e.services.locks.isLocked("HW1"))
        #expect(e.model.mirrors.ai.isEmpty)
        #expect(e.services.log.entries.first?.title == "禁止 AI 操作" && e.services.log.entries.first?.source == .user)
        await e.services.setAILocked("HW1", false)
        #expect(!e.services.locks.isLocked("HW1"))
        #expect(e.services.log.entries.first?.title == "允许 AI 操作")
    }
}
