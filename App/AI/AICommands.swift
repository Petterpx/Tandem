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
            // 设备已拔出或离线：会话不会再起来，不必等满超时
            guard devices().first(where: { $0.id == id })?.state == .connected else {
                throw DeviceError(code: .DEVICE_NOT_FOUND, message: "设备已断开")
            }
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

    // MARK: 操作

    enum TapTarget: Equatable {
        case point(x: Double, y: Double)
        case index(Int)
        case text(String)
    }

    enum ScrollDirection: String, CaseIterable { case up, down, left, right }

    /// 一次点按的落点：归一化坐标、AI 空间坐标（用于结果文字）与记录标题的目标部分。
    private struct Resolved {
        let point: NormalizedPoint
        let ai: (x: Int, y: Int)
    }

    func tap(_ device: DeviceInfo, _ target: TapTarget) async throws -> String {
        let title = "tap " + targetLabel(device, target)
        return try await act(title, device) { s in
            let r = try await resolveTarget(device, target, session: s)
            await s.send(.touch(.down, r.point))
            await s.send(.touch(.up, r.point))
            presence.show(device.id, .tap(r.point), label: title)
            return "已点击 (\(r.ai.x),\(r.ai.y))"
        }
    }

    func longPress(_ device: DeviceInfo, _ target: TapTarget, durationMs: Int) async throws -> String {
        let title = "long_press " + targetLabel(device, target)
        return try await act(title, device) { s in
            let r = try await resolveTarget(device, target, session: s)
            await s.send(.touch(.down, r.point))
            try await sleep(.milliseconds(durationMs))
            await s.send(.touch(.up, r.point))
            presence.show(device.id, .longPress(r.point, seconds: Double(durationMs) / 1000), label: title)
            return "已长按 (\(r.ai.x),\(r.ai.y)) \(durationMs)ms"
        }
    }

    func swipe(
        _ device: DeviceInfo, from: (x: Double, y: Double), to: (x: Double, y: Double), durationMs: Int
    ) async throws -> String {
        let title = "swipe (\(Self.int(from.x)),\(Self.int(from.y)))→(\(Self.int(to.x)),\(Self.int(to.y)))"
        return try await act(title, device) { s in
            let space = try aiSpace(device)
            let a = space.normalized(x: from.x, y: from.y)
            let b = space.normalized(x: to.x, y: to.y)
            try await drag(s, a, b, durationMs: durationMs)
            presence.show(device.id, .swipe(a, b), label: title)
            return "已滑动 (\(Self.int(from.x)),\(Self.int(from.y)))→(\(Self.int(to.x)),\(Self.int(to.y)))"
        }
    }

    /// 滚动距离为屏幕边长的 60%；direction 是要查看的内容方向，手指朝相反方向移动。
    func scroll(_ device: DeviceInfo, _ direction: ScrollDirection, at: (x: Double, y: Double)?) async throws -> String {
        let title = "scroll \(direction.rawValue)"
        return try await act(title, device) { s in
            let space = try aiSpace(device)
            let c = at.map { space.normalized(x: $0.x, y: $0.y) } ?? NormalizedPoint(x: 0.5, y: 0.5)
            func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
            var a = c, b = c
            switch direction {
            case .down: (a.y, b.y) = (clamp(c.y + 0.3), clamp(c.y - 0.3))
            case .up: (a.y, b.y) = (clamp(c.y - 0.3), clamp(c.y + 0.3))
            case .right: (a.x, b.x) = (clamp(c.x + 0.3), clamp(c.x - 0.3))
            case .left: (a.x, b.x) = (clamp(c.x - 0.3), clamp(c.x + 0.3))
            }
            try await drag(s, a, b, durationMs: 300)
            presence.show(device.id, .swipe(a, b), label: title)
            return "已滚动 \(direction.rawValue)"
        }
    }

    func typeText(_ device: DeviceInfo, _ text: String, submit: Bool) async throws -> String {
        // 标题不含输入内容
        let title = "输入文字（\(text.count) 字）" + (submit ? "并回车" : "")
        return try await act(title, device) { s in
            if text.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) {
                await s.send(.text(text))
            } else {
                // 非 ASCII 无法直接注入，经设备剪贴板粘贴；用 throws 版本让失败可见
                try await s.setClipboard(text, paste: true)
            }
            if submit { await s.send(.key(.enter)) }
            presence.show(device.id, .label, label: title)
            return "已输入 \(text.count) 个字" + (submit ? "并回车" : "")
        }
    }

    func pressKey(_ device: DeviceInfo, _ key: DeviceKey) async throws -> String {
        let name = Self.keyNames.first { $0.value == key }?.key ?? key.rawValue
        let title = "press_key \(name)"
        return try await act(title, device) { s in
            await s.send(.key(key))
            presence.show(device.id, .label, label: title)
            return "已按下 \(name)"
        }
    }

    func setClipboard(_ device: DeviceInfo, text: String, paste: Bool) async throws -> String {
        let title = paste ? "写入并粘贴" : "写入剪贴板"
        return try await act(title, device) { s in
            try await clipboard.write(device.id, text: text, paste: paste, session: s)
            presence.show(device.id, .label, label: title)
            return paste ? "已写入设备剪贴板并粘贴" : "已写入设备剪贴板"
        }
    }

    private static let keyNames: [String: DeviceKey] = [
        "back": .back, "home": .home, "recents": .recents, "enter": .enter, "delete": .delete, "tab": .tab,
        "up": .up, "down": .down, "left": .left, "right": .right,
        "volume_up": .volumeUp, "volume_down": .volumeDown, "power": .power,
    ]

    static func deviceKey(named: String) -> DeviceKey? { keyNames[named] }

    private static func int(_ v: Double) -> Int { Int(v.rounded()) }

    /// 操作类通用流程：touch → 查锁定 → 会话就绪 → 执行；失败进记录。
    private func act(
        _ title: String, _ device: DeviceInfo, _ body: (any DeviceSession) async throws -> String
    ) async throws -> String {
        presence.touch(device.id)
        if locks.isLocked(device.id) {
            let message = "设备已锁定，禁止 AI 操作"
            runner.note(title, device: device, source: .ai, failure: message)
            throw DeviceError(
                code: .AI_LOCKED, message: message, suggestion: "请在 Tandem 的「AI」标签中关闭「禁止 AI 操作」")
        }
        return try await run(title, device, logSuccess: true) {
            let s = try await runningSession(device)
            return try await body(s)
        }
    }

    private func aiSpace(_ device: DeviceInfo) throws -> CoordinateSpace {
        guard case .running(let w, let h) = sessionState(device.id),
            let space = CoordinateSpace(screenWidth: Double(w), screenHeight: Double(h))
        else { throw DeviceError(code: .UNSUPPORTED, message: "投屏未运行", suggestion: "请在 Tandem 中打开该设备") }
        return space
    }

    /// 标题里的目标部分：坐标取整，序号取缓存元素的文字或 desc。
    private func targetLabel(_ device: DeviceInfo, _ target: TapTarget) -> String {
        switch target {
        case .point(let x, let y): return "(\(Self.int(x)),\(Self.int(y)))"
        case .text(let s): return s
        case .index(let n):
            guard let e = trees[device.id]?.element(index: n) else { return "#\(n)" }
            return [e.text, e.contentDescription].first { !$0.isEmpty } ?? "#\(n)"
        }
    }

    private func resolveTarget(_ device: DeviceInfo, _ target: TapTarget, session: any DeviceSession) async throws
        -> Resolved
    {
        switch target {
        case .point(let x, let y):
            let space = try aiSpace(device)
            return Resolved(point: space.normalized(x: x, y: y), ai: (Self.int(x), Self.int(y)))
        case .index(let n):
            guard let tree = trees[device.id], let e = tree.element(index: n) else {
                throw DeviceError(
                    code: .ELEMENT_NOT_FOUND, message: "没有序号为 \(n) 的元素", suggestion: "请先调用 get_ui_tree")
            }
            return resolved(tree, e)
        case .text(let s):
            let tree = try await deviceActions(device).uiTree()
            trees[device.id] = tree
            // 忽略没有面积的隐藏节点
            let visible = UITree(screen: tree.screen, elements: tree.elements.filter { !$0.bounds.isEmpty })
            let found = visible.matching(text: s)
            switch found.count {
            case 0:
                throw DeviceError(
                    code: .ELEMENT_NOT_FOUND, message: "没有找到文字为「\(s)」的元素", suggestion: "请先调用 get_ui_tree 查看界面")
            case 1: return resolved(tree, found[0])
            default:
                throw DeviceError(
                    code: .ELEMENT_AMBIGUOUS,
                    message: "匹配到多个元素：\n" + found.map { tree.line(for: $0) }.joined(separator: "\n"),
                    suggestion: "请改用序号或坐标")
            }
        }
    }

    private func resolved(_ tree: UITree, _ e: UIElement) -> Resolved {
        let p = tree.normalizedCenter(e)
        let ai = tree.space?.point(p) ?? (Self.int(e.center.x), Self.int(e.center.y))
        return Resolved(point: p, ai: ai)
    }

    /// down 在起点，按 16ms 一步线性插值发 move，最后在终点 up。
    private func drag(_ s: any DeviceSession, _ a: NormalizedPoint, _ b: NormalizedPoint, durationMs: Int) async throws {
        await s.send(.touch(.down, a))
        let steps = max(1, durationMs / 16)
        for i in 1...steps {
            try await sleep(.milliseconds(16))
            let t = Double(i) / Double(steps)
            await s.send(.touch(.move, NormalizedPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))
        }
        await s.send(.touch(.up, b))
    }

    // MARK: 内部

    private func deviceActions(_ device: DeviceInfo) async throws -> any DeviceActions {
        guard let a = await actions(device.id) else {
            throw DeviceError(code: .DEVICE_NOT_FOUND, message: "设备不可用", suggestion: "请检查设备连接后重试")
        }
        return a
    }

    /// 经 ActionRunner 执行（来源 .ai；感知类成功不写记录，操作类成功写记录）；失败照常进记录，并把原错误抛给调用方。
    private func run<T>(
        _ title: String, _ device: DeviceInfo, logSuccess: Bool = false, _ body: () async throws -> T
    ) async throws -> T {
        var failure: (any Error)?
        let value = await runner.perform(title, device: device, source: .ai, logSuccess: logSuccess) { () async throws -> T in
            do { return try await body() } catch {
                failure = error
                throw error
            }
        }
        if let value { return value }
        throw failure ?? CancellationError()
    }
}
