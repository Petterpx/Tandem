import DeviceCore
import Foundation

/// App 级服务：只创建一次，共用同一个 MacPasteboard（剪贴板同步据此识别 App 自己的写入）。
@MainActor
final class AppServices {
    let model: AppModel
    let pasteboard: MacPasteboard
    let store: CaptureStore
    let log: ActivityLog
    let runner: ActionRunner
    let toasts: ToastCenter
    let recording: RecordingService
    let clipboard: ClipboardService
    let commands: DeviceCommands

    init(model: AppModel, pasteboard: MacPasteboard = MacPasteboard(), defaults: UserDefaults = .standard) {
        self.model = model
        self.pasteboard = pasteboard
        store = CaptureStore(pasteboard: pasteboard, defaults: defaults)
        log = ActivityLog()
        runner = ActionRunner(log: log)
        toasts = ToastCenter()
        recording = RecordingService(store: store)
        clipboard = ClipboardService(pasteboard: pasteboard, defaults: defaults)
        commands = DeviceCommands(
            runner: runner, store: store, recording: recording, clipboard: clipboard, toasts: toasts,
            // 设备离开列表后沿用最后一次的信息，录屏收尾与记录仍有设备名
            device: { id in model.devices.first { $0.id == id } ?? model.lastKnownDevices[id] },
            // 只有 running 的会话才可用：停止 / 失败后的会话对象仍留在模型里，但不会再产生画面。
            session: { Self.runningOnly(model.sessionStates[$0], model.session(for: $0)) },
            actions: { await model.actions(for: $0) },
            isPopupOpen: { model.mirrors.popped.contains($0) })
    }

    /// 把 AppModel 的会话结束与设备剪贴板事件接到服务上。
    func connect() {
        let model = model
        let commands = commands
        let clipboard = clipboard
        model.onSessionEnded = { id, reason in
            // 退出时由 shutdown 统一收尾并等待；这里不再起一个没人等待的收尾任务。
            guard reason != .quit else { return }
            Task { await commands.sessionEnded(id, reason: reason) }
        }
        model.onDeviceClipboard = { clipboard.deviceClipboardChanged($0, text: $1) }
    }

    /// 退出 App：录屏收尾与停止会话并发进行，两者都完成后返回（期限由调用方控制）。
    /// 停止会话放进子任务（要等主线程空出来才开始）；录屏收尾在这里直接调用，第一次挂起前就同步摘除所有录屏，
    /// 所以停会话引起的断开事件不会再抢到录屏。
    func shutdown() async {
        let model = model
        async let sessions: Void = model.stopAll()
        await commands.stopAllRecordings()
        await sessions
    }

    /// 状态为 running 才返回会话，否则 nil（录屏 / 剪贴板等所有入口共用）。
    static func runningOnly(_ state: SessionState?, _ session: (any DeviceSession)?) -> (any DeviceSession)? {
        if case .running = state { return session }
        return nil
    }

    /// 剪贴板同步循环使用的会话：只取状态为 running 的设备。
    static func runningSessions(of model: AppModel) -> [String: any DeviceSession] {
        var result: [String: any DeviceSession] = [:]
        for (id, state) in model.sessionStates {
            guard case .running = state, let session = model.session(for: id) else { continue }
            result[id] = session
        }
        return result
    }
}
