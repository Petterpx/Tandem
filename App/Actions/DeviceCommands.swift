import DeviceCore
import Foundation
import Observation

/// 面板操作的唯一入口：经 ActionRunner 执行，结果交给 CaptureStore / ToastCenter / ClipboardService。
@MainActor @Observable
final class DeviceCommands {
    // runner、transfers、device、actions 不设 private：DeviceCommands+QuickActions / +Transfers 扩展文件要用
    let runner: ActionRunner
    private let store: CaptureStore
    private let recording: RecordingService
    private let clipboard: ClipboardService
    private let toasts: ToastCenter
    let transfers: TransferQueue
    let device: (String) -> DeviceInfo?
    private let session: (String) -> (any DeviceSession)?
    let actions: (String) async -> (any DeviceActions)?
    /// 某台设备的弹出窗口是否仍打开（自动结束录屏时决定提示条位置）。
    private let isPopupOpen: (String) -> Bool
    /// 开始录屏时记住的设备：设备被移除后仍能收尾并写记录。
    @ObservationIgnored private var recordingDevices: [String: DeviceInfo] = [:]

    init(
        runner: ActionRunner, store: CaptureStore, recording: RecordingService, clipboard: ClipboardService,
        toasts: ToastCenter, transfers: TransferQueue, device: @escaping (String) -> DeviceInfo?,
        session: @escaping (String) -> (any DeviceSession)?,
        actions: @escaping (String) async -> (any DeviceActions)?,
        isPopupOpen: @escaping (String) -> Bool
    ) {
        self.runner = runner
        self.store = store
        self.recording = recording
        self.clipboard = clipboard
        self.toasts = toasts
        self.transfers = transfers
        self.device = device
        self.session = session
        self.actions = actions
        self.isPopupOpen = isPopupOpen
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
        if recording.isRecording(id) {
            guard let dev = device(id) ?? recordingDevices[id] else { return }
            let item = await runner.perform("结束录屏", device: dev) { try await recording.stop(id) }
            recordingDevices[id] = nil
            // 手动结束：提示条出现在按下「结束录屏」的窗口
            if let item { toasts.show(item, note: nil, in: origin) }
        } else {
            guard let dev = device(id) else { return }
            await runner.perform("开始录屏", device: dev) {
                guard let session = session(id) else {
                    throw DeviceError(code: .UNSUPPORTED, message: "投屏未运行，无法录屏")
                }
                try recording.start(id, deviceName: dev.name, session: session, origin: origin)
                recordingDevices[id] = dev
            }
        }
    }

    /// 会话结束时自动收尾录屏；该设备没有在录屏则什么都不做。
    func sessionEnded(_ id: String, reason: SessionEndReason) async {
        guard recording.isRecording(id), let dev = device(id) ?? recordingDevices[id] else { return }
        // 自动结束：回到开始录屏的窗口；那是已关闭的弹出窗口时改在工作台显示
        var origin = recording.active[id]?.origin ?? .workspace
        if case .popup(let popupID) = origin, !isPopupOpen(popupID) { origin = .workspace }
        let (title, note): (String, String?) = switch reason {
        case .disconnected: ("录屏已自动结束（设备已断开）", "设备已断开，已保存已录制部分")
        case .stopped: ("录屏已自动结束（已停止投屏）", "已停止投屏，已保存已录制部分")
        case .quit: ("录屏已自动结束（退出）", nil)
        }
        // 上面的 isRecording 检查与 stop 的同步摘除之间没有挂起点（主线程），不会与并发 stop 竞争
        let item = await runner.perform(title, device: dev) { try await recording.stop(id) }
        recordingDevices[id] = nil
        if let item, let note { toasts.show(item, note: note, in: origin) }
    }

    /// 结束所有录屏（退出 App 时）：只写记录，不弹提示条。
    func stopAllRecordings() async {
        let results = await recording.stopAll()
        for (id, result) in results {
            let known = device(id) ?? recordingDevices[id]
            recordingDevices[id] = nil
            guard let dev = known else { continue }
            let failure: String? = if case .failure(let error) = result { Self.message(error) } else { nil }
            runner.note("录屏已自动结束（退出）", device: dev, failure: failure)
        }
    }

    private static func message(_ error: any Error) -> String {
        if let e = error as? DeviceError { return e.message }
        return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: 剪贴板

    func readClipboard(_ id: String) async {
        guard let dev = device(id) else { return }
        await runner.perform("读取剪贴板", device: dev) {
            do {
                _ = try await clipboard.read(id, session: try requireSession(id))
            } catch let error as DeviceError where error.code == .TIMEOUT {
                // 设备剪贴板为空或是图片时 scrcpy 不应答，读取只会超时
                throw DeviceError(code: .TIMEOUT, message: error.message, suggestion: "设备剪贴板可能为空或不是文本")
            }
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
