import AppKit
import DeviceCore
import Foundation
@testable import Tandem

/// AICommands 的测试环境：设备列表、会话、会话状态与设备操作都是可变属性，测试中途改动即可影响 AICommands。
@MainActor
final class AIEnv {
    nonisolated static let pixel = DeviceInfo(
        serial: "s1", platform: .android, name: "Pixel", state: .connected, connection: .usb,
        hardwareSerial: "HW1", capabilities: [.mirror, .touch, .keys, .text, .clipboard, .screenshot, .uiTree])

    var devices: [DeviceInfo]
    /// 按逻辑 id 的会话（视为 running，与 AppServices.runningOnly 的结果一致）。
    var sessions: [String: any DeviceSession]
    var states: [String: SessionState] = [:]
    /// 按逻辑 id 的设备操作（FakeActions 或 RecordingActions）。
    var actions: [String: any DeviceActions]
    /// acquire 被调用的记录。
    private(set) var acquired: [String] = []
    /// acquire 时执行，用来模拟会话稍后就绪或失败。
    var onAcquire: ((String) -> Void)?
    /// 已在 MirrorSet.wanted 中的设备（acquire 不会再启动它们的会话）。
    var wanted: Set<String> = []
    /// restart 被调用的记录。
    private(set) var restarted: [String] = []
    /// restart 时执行，用来模拟重启后会话就绪。
    var onRestart: ((String) -> Void)?

    let fake = FakeDeviceSession()
    let log = ActivityLog()
    let runner: ActionRunner
    let presence = AIPresence()
    let locks = AILocks(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    let raw = NSPasteboard(name: .init(UUID().uuidString))
    let clipboard: ClipboardService
    private(set) var transfers: TransferQueue!
    /// 拉取目录。
    let pullDir = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-ai-\(UUID().uuidString)")
    private(set) var commands: AICommands!

    init(
        devices: [DeviceInfo] = [AIEnv.pixel], actions: any DeviceActions = FakeActions(), hasSession: Bool = true,
        sessionWait: Duration = .milliseconds(300),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.devices = devices
        sessions = hasSession ? [Self.pixel.id: fake] : [:]
        self.actions = [Self.pixel.id: actions]
        runner = ActionRunner(log: log)
        clipboard = ClipboardService(
            pasteboard: MacPasteboard(raw), defaults: UserDefaults(suiteName: UUID().uuidString)!)
        let devicesNow: () -> [DeviceInfo] = { [unowned self] in self.devices }
        transfers = TransferQueue(
            runner: runner, device: { id in devicesNow().first { $0.id == id } },
            actions: { [unowned self] in self.actions[$0] }, onFinished: { _ in })
        try? FileManager.default.createDirectory(at: pullDir, withIntermediateDirectories: true)
        commands = AICommands(
            runner: runner, clipboard: clipboard, presence: presence, locks: locks,
            devices: { [unowned self] in self.devices },
            session: { [unowned self] in self.sessions[$0] },
            sessionState: { [unowned self] in self.states[$0] },
            actions: { [unowned self] in self.actions[$0] },
            acquire: { [unowned self] id in
                self.acquired.append(id)
                self.onAcquire?(id)
            },
            isWanted: { [unowned self] in self.wanted.contains($0) },
            restart: { [unowned self] id in
                self.restarted.append(id)
                self.onRestart?(id)
            },
            transfers: transfers, pullDirectory: { [unowned self] in self.pullDir }, origin: { _ in .workspace },
            sessionWait: sessionWait, sleep: sleep)
    }

    /// 测试用元素：默认可点击、有面积。
    nonisolated static func element(
        _ index: Int, _ className: String = "android.widget.Button", text: String = "", desc: String = "",
        id: String = "", bounds: CGRect = CGRect(x: 0, y: 0, width: 100, height: 100), clickable: Bool = true
    ) -> UIElement {
        UIElement(
            index: index, className: className, text: text, contentDescription: desc, resourceID: id, bounds: bounds,
            clickable: clickable, longClickable: false, scrollable: false, checkable: false, editable: false)
    }

    /// 1080x2400 屏幕上的树。
    nonisolated static func tree(_ elements: [UIElement]) -> UITree {
        UITree(screen: CGSize(width: 1080, height: 2400), elements: elements)
    }

    /// 指定尺寸的纯色 PNG（模拟 screencap）。
    nonisolated static func png(width: Int, height: Int) -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0, green: 0.5, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, context.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }
}
