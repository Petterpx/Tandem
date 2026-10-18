import DeviceCore
import Foundation
import MediaKit

/// AI 工具的执行层：设备解析、会话就绪与各工具的执行，与 DeviceCommands 并列，同样经 ActionRunner 执行（来源 .ai）。
/// 不复用 DeviceCommands 的截图等路径：那些会存文件、写 Mac 剪贴板、弹提示条。
@MainActor
final class AICommands {
    /// 等待会话启动时的检查间隔。
    static let sessionPollInterval: Duration = .milliseconds(100)
    /// wait_for 单次读取失败后的停顿，避免设备不可用时空转。
    static let retryPause: Duration = .milliseconds(100)

    private let runner: ActionRunner
    private let clipboard: ClipboardService
    private let presence: AIPresence
    private let locks: AILocks
    private let devices: () -> [DeviceInfo]
    /// 只返回 running 的会话（与 AppServices.runningOnly 相同）。
    private let session: (String) -> (any DeviceSession)?
    private let sessionState: (String) -> SessionState?
    private let actions: (String) async -> (any DeviceActions)?
    /// 让 AI 开始使用设备（加入 MirrorSet.ai 并按需启动会话）。
    private let acquire: (String) async -> Void
    private let sessionWait: Duration
    /// 操作类工具的时间间隔（长按、滑动），测试中可换成不等待的版本。
    private let sleep: @Sendable (Duration) async throws -> Void
    /// 每台设备最近一次读到的 UI 树，供按序号查找元素。
    private var trees: [String: UITree] = [:]

    init(
        runner: ActionRunner, clipboard: ClipboardService, presence: AIPresence, locks: AILocks,
        devices: @escaping () -> [DeviceInfo],
        session: @escaping (String) -> (any DeviceSession)?,
        sessionState: @escaping (String) -> SessionState?,
        actions: @escaping (String) async -> (any DeviceActions)?,
        acquire: @escaping (String) async -> Void,
        sessionWait: Duration = .seconds(10),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.runner = runner
        self.clipboard = clipboard
        self.presence = presence
        self.locks = locks
        self.devices = devices
        self.session = session
        self.sessionState = sessionState
        self.actions = actions
        self.acquire = acquire
        self.sessionWait = sessionWait
        self.sleep = sleep
    }

    func cachedTree(_ id: String) -> UITree? { trees[id] }

    // MARK: 设备解析

    /// 依次按逻辑 id、adb serial、设备名（不区分大小写的完全匹配）查找；省略时只看已连接的设备。
    func resolve(_ query: String?) throws -> DeviceInfo {
        let all = devices()
        guard let query else {
            let connected = all.filter { $0.state == .connected }
            switch connected.count {
            case 0: throw DeviceError(code: .DEVICE_NOT_FOUND, message: "没有已连接的设备")
            case 1: return connected[0]
            default:
                throw DeviceError(
                    code: .DEVICE_AMBIGUOUS, message: "连接了多台设备，请用 device 参数指定：" + Self.choices(connected))
            }
        }
        let found: DeviceInfo
        if let d = all.first(where: { $0.id == query }) ?? all.first(where: { $0.serial == query }) {
            found = d
        } else {
            let named = all.filter { $0.name.lowercased() == query.lowercased() }
            if named.count > 1 {
                throw DeviceError(
                    code: .DEVICE_AMBIGUOUS, message: "有多台设备名为 \(query)，请用 id 指定：" + Self.choices(named))
            }
            guard let d = named.first else {
                throw DeviceError(
                    code: .DEVICE_NOT_FOUND, message: "未找到设备 \(query)", suggestion: "请先调用 list_devices 查看可用设备")
            }
            found = d
        }
        switch found.state {
        case .connected: return found
        case .unauthorized: throw DeviceError(code: .DEVICE_UNAUTHORIZED, message: "请在手机上允许 USB 调试")
        case .offline: throw DeviceError(code: .DEVICE_NOT_FOUND, message: "设备已断开")
        }
    }

    private static func choices(_ list: [DeviceInfo]) -> String {
        list.map { "\($0.name)（\($0.id)）" }.joined(separator: "、")
    }

    func listDevices() -> String {
        let list = devices()
        guard !list.isEmpty else { return "没有发现设备" }
        return list.map { d in
            let connection = d.connection == .usb ? "USB" : "Wi-Fi"
            let state = switch d.state {
            case .connected: "已连接"
            case .unauthorized: "未授权"
            case .offline: "离线"
            }
            let mirroring = session(d.id) == nil ? "未投屏" : "投屏中"
            let ai = locks.isLocked(d.id) ? "禁止 AI" : "AI 可操作"
            return "- \(d.name) (id=\(d.id), \(d.platform.rawValue), \(connection), \(state), \(mirroring), \(ai))"
        }.joined(separator: "\n")
    }

    // MARK: 会话就绪

    /// 返回 running 的会话；没有则（设备未锁定时）启动并等待，最多 sessionWait。
    /// 等待期间会话失败立即抛出其原因，不拖到超时。
    func runningSession(_ device: DeviceInfo) async throws -> any DeviceSession {
        let id = device.id
        if let s = session(id) { return s }
        guard !locks.isLocked(id) else {
            throw DeviceError(code: .UNSUPPORTED, message: "投屏未运行", suggestion: "请在 Tandem 中打开该设备")
        }
        await acquire(id)
        if let s = session(id) { return s }
        // 先等一个间隔再看失败状态：刚启动时状态里可能还是上一次的失败，要给新状态送达的时间
        let polls = max(1, Int(sessionWait / Self.sessionPollInterval))
        for _ in 0..<polls {
            try await Task.sleep(for: Self.sessionPollInterval)
            if let s = session(id) { return s }
            if case .failed(let error) = sessionState(id) { throw error }
        }
        throw DeviceError.timeout("等待投屏启动")
    }

    // MARK: 感知

    /// 会话有画面且不要求高清时用最新帧（JPEG），否则走 screencap（PNG）；都缩放到 AI 坐标空间。
    func screenshot(_ device: DeviceInfo, hq: Bool) async throws -> (ScreenshotEncoder.Output, source: String) {
        presence.touch(device.id)
        return try await run("screenshot", device) {
            if !hq, let frame = session(device.id)?.latestFrame() {
                return (try ScreenshotEncoder.encodeFrame(frame.pixelBuffer), source: "投屏帧")
            }
            let png = try await deviceActions(device).screenshot()
            return (try ScreenshotEncoder.encodePNG(png), source: "screencap")
        }
    }

    /// 一行一个元素；结果按设备缓存。
    func uiTree(_ device: DeviceInfo, all: Bool) async throws -> String {
        presence.touch(device.id)
        return try await run("get_ui_tree", device) {
            let tree = try await deviceActions(device).uiTree()
            trees[device.id] = tree
            let lines = tree.lines(all: all)
            return lines.isEmpty ? "界面上没有可列出的元素" : lines.joined(separator: "\n")
        }
    }

    /// 反复读 UI 树直到出现匹配的可见元素（忽略没有面积的隐藏节点），返回该元素一行并更新缓存。
    func waitFor(_ device: DeviceInfo, text: String?, id: String?, timeout: Duration) async throws -> String {
        presence.touch(device.id)
        let deadline = ContinuousClock.now + timeout
        return try await run("wait_for \(text ?? id ?? "")", device) {
            while true {
                do {
                    let tree = try await deviceActions(device).uiTree()
                    let visible = UITree(screen: tree.screen, elements: tree.elements.filter { !$0.bounds.isEmpty })
                    if let element = visible.first(text: text, id: id) {
                        trees[device.id] = tree
                        return tree.line(for: element)
                    }
                } catch {
                    // 单次读取失败不中断等待；稍停再读
                    if ContinuousClock.now < deadline { try await Task.sleep(for: Self.retryPause) }
                }
                if ContinuousClock.now >= deadline { throw DeviceError.timeout("等待元素") }
            }
        }
    }

    /// 读设备剪贴板：不写 Mac 剪贴板与面板预览，历史照常记录。
    func getClipboard(_ device: DeviceInfo) async throws -> String {
        presence.touch(device.id)
        return try await run("get_clipboard", device) {
            let s = try await runningSession(device)
            do {
                return try await clipboard.read(device.id, session: s, showInPanel: false)
            } catch let error as DeviceError where error.code == .TIMEOUT {
                // 设备剪贴板为空或是图片时 scrcpy 不应答，读取只会超时
                throw DeviceError(code: .TIMEOUT, message: error.message, suggestion: "设备剪贴板可能为空或不是文本")
            }
        }
    }

    // MARK: 内部

    private func deviceActions(_ device: DeviceInfo) async throws -> any DeviceActions {
        guard let a = await actions(device.id) else {
            throw DeviceError(code: .DEVICE_NOT_FOUND, message: "设备不可用", suggestion: "请检查设备连接后重试")
        }
        return a
    }

    /// 经 ActionRunner 执行（来源 .ai，成功不写记录）；失败照常进记录，并把原错误抛给调用方。
    private func run<T>(_ title: String, _ device: DeviceInfo, _ body: () async throws -> T) async throws -> T {
        var failure: (any Error)?
        let value = await runner.perform(title, device: device, source: .ai, logSuccess: false) { () async throws -> T in
            do { return try await body() } catch {
                failure = error
                throw error
            }
        }
        if let value { return value }
        throw failure ?? CancellationError()
    }
}
