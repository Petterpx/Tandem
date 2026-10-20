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
    /// 会话状态：只有 running 时投屏的最新帧才可信，停止 / 失败 / 断开后会话对象仍留着旧帧。
    private let sessionState: (String) -> SessionState?
    let actions: (String) async -> (any DeviceActions)?
    /// 某台设备的弹出窗口是否仍打开（自动结束录屏时决定提示条位置）。
    private let isPopupOpen: (String) -> Bool
    /// 拉取保存目录（设置里的「拉取目录」）。
    let pullDirectory: () -> URL
    /// 开始录屏时记住的设备：设备被移除后仍能收尾并写记录。
    @ObservationIgnored private var recordingDevices: [String: DeviceInfo] = [:]

    init(
        runner: ActionRunner, store: CaptureStore, recording: RecordingService, clipboard: ClipboardService,
        toasts: ToastCenter, transfers: TransferQueue, device: @escaping (String) -> DeviceInfo?,
        session: @escaping (String) -> (any DeviceSession)?,
        sessionState: @escaping (String) -> SessionState?,
        actions: @escaping (String) async -> (any DeviceActions)?,
        isPopupOpen: @escaping (String) -> Bool,
        pullDirectory: @escaping () -> URL = { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads") }
    ) {
        self.runner = runner
        self.store = store
        self.recording = recording
        self.clipboard = clipboard
        self.toasts = toasts
        self.transfers = transfers
        self.device = device
        self.session = session
        self.sessionState = sessionState
        self.actions = actions
        self.isPopupOpen = isPopupOpen
        self.pullDirectory = pullDirectory
    }

    func can(_ capability: Capability, _ id: String) -> Bool {
        device(id)?.capabilities.contains(capability) ?? false
    }

    // MARK: 截图与录屏

    /// 正在截图的设备及其来源：同一设备同时只截一次，界面据此显示转圈。
    private(set) var screenshotsInFlight: [String: ScreenshotSource] = [:]

    func screenshotInFlight(_ id: String) -> ScreenshotSource? { screenshotsInFlight[id] }

    /// 普通截图取投屏最新帧；高清或没有画面时走 screencap。已有截图进行中则直接忽略，不排队。
    func screenshot(_ id: String, quality: ScreenshotQuality = .standard, origin: ToastOrigin) async {
        guard let dev = device(id) else { return }
        // 检查与登记之间不能有挂起点，连点才不会重复进入
        guard screenshotsInFlight[id] == nil else { return }
        // 不依赖 session 闭包是否已过滤：状态不是 running 一律不用旧帧，改走 screencap
        var frame: VideoFrame?
        if quality == .standard, case .running = sessionState(id) { frame = session(id)?.latestFrame() }
        let source: ScreenshotSource = frame == nil ? .screencap : .mirrorFrame
        screenshotsInFlight[id] = source
        defer { screenshotsInFlight[id] = nil }
        let saved = await runner.perform(quality.logTitle, device: dev) {
            let payload: ScreenshotPayload
            if let frame {
                payload = .frame(frame)
            } else {
                guard let actions = await actions(id) else {
                    throw DeviceError(code: .DEVICE_NOT_FOUND, message: "设备不可用，无法截图")
                }
                payload = .png(try await actions.screenshot())
            }
            return try await store.saveScreenshot(payload, deviceName: dev.name)
        }
        if let saved {
            toasts.show(saved.item, note: ScreenshotText.note(width: saved.width, height: saved.height, source: source), in: origin)
        }
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
