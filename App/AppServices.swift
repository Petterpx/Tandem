import DeviceCore
import Foundation

/// App 级服务：只创建一次，共用同一个 MacPasteboard（剪贴板同步据此识别 App 自己的写入）。
@MainActor
final class AppServices {
    let pasteboard: MacPasteboard
    let store: CaptureStore
    let log: ActivityLog
    let runner: ActionRunner
    let toasts: ToastCenter
    let recording: RecordingService
    let clipboard: ClipboardService
    let commands: DeviceCommands

    init(model: AppModel, pasteboard: MacPasteboard = MacPasteboard(), defaults: UserDefaults = .standard) {
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
            session: { model.session(for: $0) },
            actions: { await model.actions(for: $0) })
    }

    /// 把 AppModel 的会话结束与设备剪贴板事件接到服务上。
    func connect(_ model: AppModel) {
        let commands = commands
        let clipboard = clipboard
        model.onSessionEnded = { id, reason in Task { await commands.sessionEnded(id, reason: reason) } }
        model.onDeviceClipboard = { clipboard.deviceClipboardChanged($0, text: $1) }
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
