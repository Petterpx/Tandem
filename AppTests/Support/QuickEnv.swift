import AppKit
import DeviceCore
import Foundation
@testable import Tandem

/// 快捷操作测试的公共环境：带假动作的设备命令、模型与存储。
@MainActor
struct QuickEnv {
    let model: QuickActionsModel
    let store: QuickActionsStore
    let log: ActivityLog

    static let all: Set<Capability> = [.network, .apps, .openURL, .devOptions, .systemSettings, .shell]

    static func device(_ id: String, _ capabilities: Set<Capability> = all) -> DeviceInfo {
        DeviceInfo(
            serial: "s-\(id)", platform: .android, name: id, state: .connected, connection: .usb,
            hardwareSerial: id, capabilities: capabilities)
    }

    static func make(_ devices: [(DeviceInfo, RecordingActions)]) -> QuickEnv {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let mac = MacPasteboard(NSPasteboard(name: .init(UUID().uuidString)))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let captures = CaptureStore(pasteboard: mac, defaults: defaults, home: home)
        let log = ActivityLog()
        let infos = Dictionary(uniqueKeysWithValues: devices.map { ($0.0.id, $0.0) })
        let actions = Dictionary(uniqueKeysWithValues: devices.map { ($0.0.id, $0.1) })
        let runner = ActionRunner(log: log)
        let commands = DeviceCommands(
            runner: runner, store: captures, recording: RecordingService(store: captures),
            clipboard: ClipboardService(pasteboard: mac, defaults: defaults), toasts: ToastCenter(),
            transfers: TransferQueue(
                runner: runner, device: { infos[$0] }, actions: { actions[$0] }, onFinished: { _ in }),
            device: { infos[$0] }, session: { _ in nil }, sessionState: { _ in nil },
            actions: { actions[$0] }, isPopupOpen: { _ in false })
        let store = QuickActionsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        return QuickEnv(model: QuickActionsModel(commands: commands, store: store), store: store, log: log)
    }
}
