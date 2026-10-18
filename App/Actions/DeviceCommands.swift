import DeviceCore
import Foundation
import MediaKit
import Observation

/// 面板操作的唯一入口：经 ActionRunner 执行，结果交给 CaptureStore / ToastCenter / ClipboardService。
@MainActor @Observable
final class DeviceCommands {
    private let runner: ActionRunner
    private let store: CaptureStore
    private let recording: RecordingService
    private let clipboard: ClipboardService
    private let toasts: ToastCenter
    private let device: (String) -> DeviceInfo?
    private let session: (String) -> (any DeviceSession)?
    private let actions: (String) async -> (any DeviceActions)?

    init(
        runner: ActionRunner, store: CaptureStore, recording: RecordingService, clipboard: ClipboardService,
        toasts: ToastCenter, device: @escaping (String) -> DeviceInfo?,
        session: @escaping (String) -> (any DeviceSession)?,
        actions: @escaping (String) async -> (any DeviceActions)?
    ) {
        self.runner = runner
        self.store = store
        self.recording = recording
        self.clipboard = clipboard
        self.toasts = toasts
        self.device = device
        self.session = session
        self.actions = actions
    }

    func can(_ capability: Capability, _ id: String) -> Bool {
        device(id)?.capabilities.contains(capability) ?? false
    }

    // MARK: 截图与录屏

    func screenshot(_ id: String, origin: ToastOrigin) async {
        guard let dev = device(id) else { return }
        let item = await runner.perform("截图", device: dev) {
            guard let actions = await actions(id) else {
                throw DeviceError(code: .DEVICE_NOT_FOUND, message: "设备不可用，无法截图")
            }
            return try store.saveScreenshot(try await actions.screenshot(), deviceName: dev.name)
        }
        if let item { toasts.show(item, note: "已复制到剪贴板", in: origin) }
    }

    func toggleRecording(_ id: String, origin: ToastOrigin) async {
        guard let dev = device(id) else { return }
        if recording.isRecording(id) {
            let toastOrigin = recording.active[id]?.origin ?? origin
            let item = await runner.perform("结束录屏", device: dev) { try await stopRecording(id) }
            if let item { toasts.show(item, note: nil, in: toastOrigin) }
        } else {
            await runner.perform("开始录屏", device: dev) {
                guard let session = session(id) else {
                    throw DeviceError(code: .UNSUPPORTED, message: "投屏未运行，无法录屏")
                }
                try recording.start(id, deviceName: dev.name, session: session, origin: origin)
            }
        }
    }

    /// 会话结束时自动收尾录屏；该设备没有在录屏则什么都不做。
    func sessionEnded(_ id: String, reason: SessionEndReason) async {
        guard let dev = device(id), recording.isRecording(id) else { return }
        let origin = recording.active[id]?.origin ?? .workspace
        let (title, note): (String, String?) = switch reason {
        case .disconnected: ("录屏已自动结束（设备已断开）", "设备已断开，已保存已录制部分")
        case .stopped: ("录屏已自动结束（已停止投屏）", "已停止投屏，已保存已录制部分")
        case .quit: ("录屏已自动结束（退出）", nil)
        }
        // 上面的 isRecording 检查与 stop 的同步摘除之间没有挂起点（主线程），不会与并发 stop 竞争
        let item = await runner.perform(title, device: dev) { try await stopRecording(id) }
        if let item, let note { toasts.show(item, note: note, in: origin) }
    }

    /// 结束所有录屏（退出 App 时）：只写记录，不弹提示条。
    func stopAllRecordings() async {
        let results = await recording.stopAll()
        for (id, result) in results {
            guard let dev = device(id) else { continue }
            let failure: String? = if case .failure(let error) = result { Self.message(error) } else { nil }
            runner.note("录屏已自动结束（退出）", device: dev, failure: failure)
        }
    }

    private func stopRecording(_ id: String) async throws -> CaptureItem {
        do {
            return try await recording.stop(id)
        } catch RecordingError.noFrames {
            throw DeviceError(code: .UNSUPPORTED, message: "未收到画面")
        }
    }

    private static func message(_ error: any Error) -> String {
        if error as? RecordingError == .noFrames { return "未收到画面" }
        if let e = error as? DeviceError { return e.message }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: 剪贴板

    func readClipboard(_ id: String) async {
        guard let dev = device(id) else { return }
        await runner.perform("读取剪贴板", device: dev) {
            _ = try await clipboard.read(id, session: try requireSession(id))
        }
    }

    func writeClipboard(_ id: String, input: String, paste: Bool) async {
        guard let dev = device(id) else { return }
        let text: String
        switch ClipboardService.writeSource(input: input, macText: clipboard.macText) {
        case .input(let t), .macClipboard(let t): text = t
        case .unavailable: return
        }
        await runner.perform(paste ? "写入并粘贴" : "写入剪贴板", device: dev) {
            try await clipboard.write(id, text: text, paste: paste, session: try requireSession(id))
        }
    }

    func setClipboardSync(_ id: String, _ on: Bool) {
        guard let dev = device(id) else { return }
        clipboard.setSyncEnabled(id, on)
        runner.note(on ? "开启剪贴板自动同步" : "关闭剪贴板自动同步", device: dev)
    }

    private func requireSession(_ id: String) throws -> any DeviceSession {
        guard let s = session(id) else { throw DeviceError(code: .UNSUPPORTED, message: "投屏未运行") }
        return s
    }
}
