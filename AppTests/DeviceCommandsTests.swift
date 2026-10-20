import AppKit
import DeviceCore
import Foundation
import os
import Testing
@testable import Tandem

@MainActor
@Suite struct DeviceCommandsTests {
    private struct Env {
        let commands: DeviceCommands
        let log: ActivityLog
        let runner: ActionRunner
        let store: CaptureStore
        let toasts: ToastCenter
        let recording: RecordingService
        let fake: FakeDeviceSession
        let raw: NSPasteboard
    }

    private let dev = DeviceInfo(
        serial: "s1", platform: .android, name: "Pixel", state: .connected, connection: .usb,
        hardwareSerial: "HW1", capabilities: [.screenshot])

    private final class Present { var value = true }
    /// 可见的弹出窗口（逻辑 id）。
    private final class Popups { var open: Set<String> = [] }

    private func make(
        actions: FakeActions = FakeActions(), hasSession: Bool = true, present: Present = Present(),
        popups: Popups = Popups(), state: SessionState = .running(width: 64, height: 48)
    ) -> Env {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let raw = NSPasteboard(name: .init(UUID().uuidString))
        let mac = MacPasteboard(raw)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var tick = 0.0
        let store = CaptureStore(pasteboard: mac, defaults: defaults, home: home, now: {
            tick += 1
            return Date(timeIntervalSince1970: 1_760_000_000 + tick)
        })
        let log = ActivityLog()
        let runner = ActionRunner(log: log)
        let recording = RecordingService(store: store)
        let toasts = ToastCenter()
        let clipboard = ClipboardService(pasteboard: mac, defaults: defaults)
        let fake = FakeDeviceSession()
        let device = dev
        let commands = DeviceCommands(
            runner: runner, store: store, recording: recording, clipboard: clipboard, toasts: toasts,
            transfers: TransferQueue(
                runner: runner, device: { $0 == device.id ? device : nil },
                actions: { $0 == device.id ? actions : nil }, onFinished: { _ in }),
            device: { $0 == device.id && present.value ? device : nil },
            session: { $0 == device.id && hasSession ? fake : nil },
            sessionState: { $0 == device.id && hasSession ? state : nil },
            actions: { $0 == device.id ? actions : nil },
            isPopupOpen: { popups.open.contains($0) })
        return Env(commands: commands, log: log, runner: runner, store: store, toasts: toasts,
                   recording: recording, fake: fake, raw: raw)
    }

    private let size = CGSize(width: 64, height: 48)

    @Test func screenshotSavesLogsAndToasts() async {
        let e = make()
        await e.commands.screenshot("HW1", origin: .workspace)
        #expect(e.store.recent.count == 1)
        #expect(e.log.entries.first?.title == "截图")
        #expect(e.toasts.current[.workspace]?.note == "无损 · 已复制到剪贴板")
    }

    @Test func standardUsesLatestFrame() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        var fake = FakeActions()
        fake.screenshotProvider = { calls.withLock { $0 += 1 }; return Data() }
        let e = make(actions: fake)
        await e.fake.pushFrames(count: 1, size: size, fps: 30)
        await e.commands.screenshot("HW1", origin: .workspace)
        #expect(calls.withLock { $0 } == 0)
        #expect(e.toasts.current[.workspace]?.note == "64×48 · 投屏画质 · 已复制到剪贴板")
        #expect(e.log.entries.first?.title == "截图")
    }

    @Test func standardWithoutSessionFallsBackToScreencap() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        var fake = FakeActions()
        fake.screenshotProvider = { calls.withLock { $0 += 1 }; return AIEnv.png(width: 1080, height: 2400) }
        let e = make(actions: fake, hasSession: false)
        await e.commands.screenshot("HW1", origin: .workspace)
        #expect(calls.withLock { $0 } == 1)
        #expect(e.toasts.current[.workspace]?.note == "1080×2400 · 无损 · 已复制到剪贴板")
        #expect(e.log.entries.first?.title == "截图")
    }

    /// 会话对象停止 / 失败 / 断开后仍留着旧画面：默认截图不能存旧帧，要走 screencap。
    @Test(arguments: [
        SessionState.idle, .disconnected, .failed(DeviceError(code: .CONNECTION_FAILED, message: "x")),
    ])
    func staleFrameAfterStopFallsBackToScreencap(state: SessionState) async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        var fake = FakeActions()
        fake.screenshotProvider = { calls.withLock { $0 += 1 }; return AIEnv.png(width: 1080, height: 2400) }
        let e = make(actions: fake, state: state)
        await e.fake.pushFrames(count: 1, size: size, fps: 30)
        await e.commands.screenshot("HW1", origin: .workspace)
        #expect(calls.withLock { $0 } == 1)
        #expect(e.toasts.current[.workspace]?.note == "1080×2400 · 无损 · 已复制到剪贴板")
    }

    @Test func losslessIgnoresFrame() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        var fake = FakeActions()
        fake.screenshotProvider = { calls.withLock { $0 += 1 }; return AIEnv.png(width: 1080, height: 2400) }
        let e = make(actions: fake)
        await e.fake.pushFrames(count: 1, size: size, fps: 30)
        await e.commands.screenshot("HW1", quality: .lossless, origin: .workspace)
        #expect(calls.withLock { $0 } == 1)
        #expect(e.log.entries.first?.title == "高清截图")
    }

    @Test func concurrentScreenshotsAreIgnored() async throws {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let gate = TransferGate()
        var fake = FakeActions()
        fake.screenshotProvider = {
            calls.withLock { $0 += 1 }
            try await gate.wait()
            return AIEnv.png(width: 100, height: 200)
        }
        let e = make(actions: fake)
        let first = Task { await e.commands.screenshot("HW1", quality: .lossless, origin: .workspace) }
        while e.commands.screenshotInFlight("HW1") == nil { await Task.yield() }
        #expect(e.commands.screenshotInFlight("HW1") == .screencap)
        await e.commands.screenshot("HW1", origin: .workspace)
        gate.release()
        await first.value
        #expect(calls.withLock { $0 } == 1 && e.store.recent.count == 1 && e.log.entries.count == 1)
        #expect(e.commands.screenshotInFlight("HW1") == nil)
    }

    @Test func failedScreenshotClearsInFlight() async {
        let e = make(actions: FakeActions(result: .failure(DeviceError(code: .TIMEOUT, message: "超时"))))
        await e.commands.screenshot("HW1", origin: .workspace)
        #expect(e.commands.screenshotInFlight("HW1") == nil && e.toasts.current.isEmpty)
        await e.commands.screenshot("HW1", origin: .workspace)
        #expect(e.log.entries.count == 2 && e.log.entries.allSatisfy { $0.failure != nil })
    }

    @Test func screenshotFailureShowsError() async {
        let e = make(actions: FakeActions(result: .failure(DeviceError(code: .TIMEOUT, message: "超时"))))
        await e.commands.screenshot("HW1", origin: .workspace)
        #expect(e.runner.lastError != nil)
        #expect(e.store.recent.isEmpty)
        #expect(e.toasts.current.isEmpty)
    }

    @Test func toggleRecordingTwiceProducesRecording() async {
        let e = make()
        await e.commands.toggleRecording("HW1", origin: .workspace)
        #expect(e.recording.isRecording("HW1"))
        await e.fake.pushFrames(count: 30, size: size, fps: 30)
        await e.commands.toggleRecording("HW1", origin: .workspace)
        #expect(e.store.recent.first?.kind == .recording)
        #expect(e.log.entries.map(\.title) == ["结束录屏", "开始录屏"])
        #expect(e.toasts.current[.workspace] != nil)
    }

    @Test func startWithoutSessionFails() async {
        let e = make(hasSession: false)
        await e.commands.toggleRecording("HW1", origin: .workspace)
        #expect(e.runner.lastError?.message == "投屏未运行，无法录屏")
        #expect(!e.recording.isRecording("HW1"))
    }

    @Test func stopWithoutFramesSaysNoFrames() async {
        let e = make()
        await e.commands.toggleRecording("HW1", origin: .workspace)
        await e.commands.toggleRecording("HW1", origin: .workspace)
        #expect(e.runner.lastError?.message == "未收到画面")
        #expect(e.runner.lastError?.suggestion == nil)
        #expect(e.toasts.current.isEmpty)
    }

    @Test func disconnectAutoStopsWithNote() async {
        let e = make()
        await e.commands.toggleRecording("HW1", origin: .workspace)
        await e.fake.pushFrames(count: 30, size: size, fps: 30)
        await e.commands.sessionEnded("HW1", reason: .disconnected)
        #expect(e.toasts.current[.workspace]?.note == "设备已断开，已保存已录制部分")
        #expect(e.log.entries.contains { $0.title == "录屏已自动结束（设备已断开）" && $0.failure == nil })
        #expect(!e.recording.isRecording("HW1"))
    }

    @Test func stoppedAutoStopsWithNote() async {
        let popups = Popups()
        popups.open = ["HW1"]
        let e = make(popups: popups)
        await e.commands.toggleRecording("HW1", origin: .popup("HW1"))
        await e.fake.pushFrames(count: 30, size: size, fps: 30)
        await e.commands.sessionEnded("HW1", reason: .stopped)
        #expect(e.toasts.current[.popup("HW1")]?.note == "已停止投屏，已保存已录制部分")
        #expect(e.log.entries.first?.title == "录屏已自动结束（已停止投屏）")
    }

    @Test func manualStopToastsInTheWindowWhereStopWasPressed() async {
        let popups = Popups()
        popups.open = ["HW1"]
        let e = make(popups: popups)
        await e.commands.toggleRecording("HW1", origin: .workspace)
        await e.fake.pushFrames(count: 30, size: size, fps: 30)
        await e.commands.toggleRecording("HW1", origin: .popup("HW1"))
        #expect(e.toasts.current[.popup("HW1")] != nil)
        #expect(e.toasts.current[.workspace] == nil)
    }

    @Test func autoEndOfClosedPopupToastsInWorkspace() async {
        let popups = Popups()
        popups.open = ["HW1"]
        let e = make(popups: popups)
        await e.commands.toggleRecording("HW1", origin: .popup("HW1"))
        await e.fake.pushFrames(count: 30, size: size, fps: 30)
        // 关掉弹出窗口 → 会话停止 → 录屏自动结束
        popups.open = []
        await e.commands.sessionEnded("HW1", reason: .stopped)
        #expect(e.toasts.current[.workspace]?.note == "已停止投屏，已保存已录制部分")
        #expect(e.toasts.current[.popup("HW1")] == nil)
    }

    @Test func sessionEndedStopsRecordingEvenAfterDeviceIsGone() async {
        let present = Present()
        let e = make(present: present)
        await e.commands.toggleRecording("HW1", origin: .workspace)
        await e.fake.pushFrames(count: 30, size: size, fps: 30)
        present.value = false
        await e.commands.sessionEnded("HW1", reason: .stopped)
        #expect(!e.recording.isRecording("HW1") && e.store.recent.first?.kind == .recording)
        #expect(e.log.entries.first?.title == "录屏已自动结束（已停止投屏）")
        #expect(e.toasts.current[.workspace]?.note == "已停止投屏，已保存已录制部分")
    }

    @Test func stopAllRecordingsLogsEvenAfterDeviceIsGone() async {
        let present = Present()
        let e = make(present: present)
        await e.commands.toggleRecording("HW1", origin: .workspace)
        await e.fake.pushFrames(count: 30, size: size, fps: 30)
        present.value = false
        await e.commands.stopAllRecordings()
        #expect(!e.recording.isRecording("HW1") && e.store.recent.first?.kind == .recording)
        #expect(e.log.entries.first?.title == "录屏已自动结束（退出）")
    }

    @Test func sessionEndedWhenNotRecordingDoesNothing() async {
        let e = make()
        await e.commands.sessionEnded("HW1", reason: .disconnected)
        await e.commands.sessionEnded("unknown", reason: .stopped)
        #expect(e.log.entries.isEmpty && e.toasts.current.isEmpty && e.runner.lastError == nil)
    }

    @Test func stopAllRecordingsLogsQuitWithoutToast() async {
        let e = make()
        await e.commands.toggleRecording("HW1", origin: .workspace)
        await e.fake.pushFrames(count: 30, size: size, fps: 30)
        await e.commands.stopAllRecordings()
        #expect(e.log.entries.first?.title == "录屏已自动结束（退出）")
        #expect(e.toasts.current.isEmpty && !e.recording.isRecording("HW1"))
        #expect(e.store.recent.first?.kind == .recording)
    }

    @Test func unavailableWriteDoesNothing() async {
        let e = make()
        e.raw.clearContents()
        await e.commands.writeClipboard("HW1", input: "", paste: false)
        #expect(e.fake.setClipboardCalls.isEmpty && e.log.entries.isEmpty)
    }

    @Test func writeUsesInputAndPasteTitle() async {
        let e = make()
        await e.commands.writeClipboard("HW1", input: "abc", paste: true)
        #expect(e.fake.setClipboardCalls.first?.text == "abc" && e.fake.setClipboardCalls.first?.paste == true)
        #expect(e.log.entries.first?.title == "写入并粘贴")
    }

    @Test func readClipboardLogsAndSyncToggleNotes() async {
        let e = make()
        e.fake.clipboardResult = .success("hi")
        await e.commands.readClipboard("HW1")
        #expect(e.log.entries.first?.title == "读取剪贴板")
        e.commands.setClipboardSync("HW1", true)
        #expect(e.log.entries.first?.title == "开启剪贴板自动同步")
        e.commands.setClipboardSync("HW1", false)
        #expect(e.log.entries.first?.title == "关闭剪贴板自动同步")
    }

    @Test func readTimeoutSuggestsEmptyOrNonTextClipboard() async {
        let e = make()
        e.fake.clipboardResult = .failure(DeviceError.timeout("读取剪切板"))
        await e.commands.readClipboard("HW1")
        #expect(e.runner.lastError?.message == "读取剪切板超时")
        #expect(e.runner.lastError?.suggestion == "设备剪贴板可能为空或不是文本")
        #expect(e.log.entries.first?.failure == "读取剪切板超时")
    }

    @Test func canChecksCapabilities() {
        let e = make()
        #expect(e.commands.can(.screenshot, "HW1") && !e.commands.can(.record, "HW1") && !e.commands.can(.screenshot, "x"))
    }
}
