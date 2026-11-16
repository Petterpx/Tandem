import ControlProtocol
import DeviceCore
import Foundation
import ImageIO
import Observation

/// An in-app task owns one fixed device. All input still passes through the
/// existing AICommands/session path, including locks, gesture cleanup and logs.
@MainActor @Observable
final class PhoneAgent {
    private(set) var runs: [String: PhoneAgentRun] = [:]
    private(set) var activeDeviceID: String?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let planner: any PhoneAgentPlanning
    @ObservationIgnored private let configuration: () throws -> PhoneAgentConfiguration
    @ObservationIgnored private let device: (String) -> DeviceInfo?
    @ObservationIgnored private let isLocked: (String) -> Bool
    @ObservationIgnored private let descriptors: (DeviceInfo) -> [ToolDescriptor]
    @ObservationIgnored private let call: (String, [String: JSONValue]) async throws -> ToolResult
    @ObservationIgnored private let release: (String) async -> Void
    @ObservationIgnored private let maxSteps: Int
    @ObservationIgnored private let settle: Duration
    // Only deliberate questions retain resumable state; uncertain device input
    // failures and cancellation must never become automatic retries.
    private var continuations: [String: Continuation] = [:]
    private struct Continuation {
        let goal: String
        var history: [PhoneAgentHistory] = []
        var userReplies: [String] = []
        var resumeCount = 0
        var applicationCatalog: String?
        var catalogAttempted = false
    }
    private let totalActionLimit = 60

    init(
        planner: any PhoneAgentPlanning = PhoneAgentPlanner(),
        configuration: @escaping () throws -> PhoneAgentConfiguration,
        device: @escaping (String) -> DeviceInfo?, isLocked: @escaping (String) -> Bool,
        descriptors: @escaping (DeviceInfo) -> [ToolDescriptor],
        call: @escaping (String, [String: JSONValue]) async throws -> ToolResult,
        release: @escaping (String) async -> Void,
        maxSteps: Int = 24, settle: Duration = .milliseconds(650)
    ) {
        self.planner = planner; self.configuration = configuration
        self.device = device; self.isLocked = isLocked
        self.descriptors = descriptors; self.call = call; self.release = release
        self.maxSteps = max(1, maxSteps); self.settle = settle
    }

    func start(goal: String, deviceID: String) {
        guard activeDeviceID == nil else { return }
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else { return }
        continuations[deviceID] = nil
        runs[deviceID] = PhoneAgentRun(goal: goal, status: .thinking, steps: [], message: "正在读取当前画面")
        do {
            guard goal.count <= 8_000 else { throw AgentError("需求过长，请控制在 8000 字以内") }
            _ = try availableDevice(deviceID)
            let config = try configuration()
            activeDeviceID = deviceID
            task = Task { await self.execute(context: Continuation(goal: goal), id: deviceID, configuration: config) }
        } catch {
            update(deviceID, .failed, error.localizedDescription)
        }
    }

    func canResume(deviceID: String) -> Bool {
        runs[deviceID]?.status == .needsUser && continuations[deviceID] != nil
    }

    /// Re-observe the same device after a reply/manual step; prior actions are
    /// evidence for the planner, never a queue to execute again.
    func resume(deviceID: String, reply: String = "") {
        guard activeDeviceID == nil, canResume(deviceID: deviceID),
              var context = continuations[deviceID] else { return }
        do {
            let reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard reply.count <= 8_000 else { throw AgentError("补充过长，请控制在 8000 字以内") }
            _ = try availableDevice(deviceID)
            let config = try configuration()
            context.userReplies.append(reply)
            context.resumeCount += 1
            continuations[deviceID] = nil
            activeDeviceID = deviceID
            update(deviceID, .thinking, "正在重新读取当前画面")
            task = Task { await self.execute(context: context, id: deviceID, configuration: config) }
        } catch {
            continuations[deviceID] = nil
            update(deviceID, .failed, error.localizedDescription)
        }
    }

    func stop() {
        guard let id = activeDeviceID, runs[id]?.status.isRunning == true else { return }
        update(id, .stopping, "正在结束当前操作")
        task?.cancel()
    }

    func clear(deviceID: String) {
        guard activeDeviceID != deviceID else { return }
        runs[deviceID] = nil
        continuations[deviceID] = nil
    }

    func waitUntilFinished() async { await task?.value }

    private func execute(context initial: Continuation, id: String, configuration: PhoneAgentConfiguration) async {
        var context = initial
        var history = context.history
        let segmentStart = history.count
        let clock = ContinuousClock()
        let started = clock.now
        do {
            for turn in 1...(maxSteps + 1) {
                try Task.checkCancellation()
                guard clock.now - started < .seconds(600) else {
                    throw AgentError("已达到 10 分钟时限，请确认当前画面后重新提出需求")
                }
                let current = try availableDevice(id)
                update(id, .thinking, "正在观察第 \(turn) 步的画面")
                let observation = try await call("screenshot", ["device": .string(id), "hq": false])
                try Task.checkCancellation()
                guard !observation.isError,
                      let image = observation.content.compactMap({ content -> (Data, String)? in
                          if case .image(let data, let mime) = content { return (data, mime) }
                          return nil
                      }).first else {
                    throw AgentError(Self.text(observation).isEmpty ? "未取得手机画面" : Self.text(observation))
                }
                guard let source = CGImageSourceCreateWithData(image.0 as CFData, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int,
                      width > 0, height > 0 else { throw AgentError("手机截图无法读取，已停止") }
                let tools = Self.scopedTools(descriptors(current), device: current)
                if !context.catalogAttempted {
                    context.catalogAttempted = true
                    if current.capabilities.contains(.appLaunch), tools.contains(where: { $0.name == "list_apps" }) {
                        update(id, .thinking, "正在读取应用列表")
                        do {
                            let catalog = try await call("list_apps", ["device": .string(id)])
                            if !catalog.isError {
                                context.applicationCatalog = String(Self.text(catalog).prefix(60_000))
                            }
                        } catch {
                            // Metadata is an optimization. A failed read leaves
                            // screenshot navigation available, without retrying.
                            if Task.isCancelled { throw CancellationError() }
                        }
                        try Task.checkCancellation()
                    }
                }
                let input = PhoneAgentInput(
                    goal: context.goal, deviceName: current.name, platform: current.platform.rawValue,
                    tools: tools, image: image.0, mimeType: image.1,
                    screenDescription: Self.text(observation), history: history, step: history.count + 1,
                    userReplies: context.userReplies, applicationCatalog: context.applicationCatalog)
                let planningStarted = clock.now
                let decision = try await planner.decide(input, configuration: configuration)
                let planningSeconds = Self.seconds(clock.now - planningStarted)
                try Task.checkCancellation()
                // A lock/disconnect/capability change during model inference must
                // stop the pending input before it reaches the device.
                let latest = try availableDevice(id)
                let allowed = Self.scopedTools(descriptors(latest), device: latest)
                guard !decision.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      decision.summary.count <= 4_000 else { throw AgentError("模型返回了无效的步骤说明") }
                switch decision.kind {
                case .done:
                    update(id, .completed, decision.summary)
                    await finish(id)
                    return
                case .ask:
                    if history.count < totalActionLimit, context.resumeCount < 60 {
                        context.history = history
                        continuations[id] = context
                    }
                    update(id, .needsUser, decision.summary)
                    await finish(id)
                    return
                case .act:
                    guard history.count < totalActionLimit else {
                        update(id, .needsUser, "任务已达到 60 步上限，请检查当前画面后提出新需求")
                        await finish(id)
                        return
                    }
                    guard history.count - segmentStart < maxSteps else {
                        if context.resumeCount < 60 {
                            context.history = history
                            continuations[id] = context
                        }
                        update(id, .needsUser, "本轮已执行 \(maxSteps) 步，可检查当前画面后继续执行")
                        await finish(id)
                        return
                    }
                    var arguments = try Self.validatedArguments(decision, tools: allowed, screenSize: (width, height))
                    arguments["device"] = .string(id)
                    let step = PhoneAgentStep(
                        id: UUID(), number: history.count + 1, summary: decision.summary,
                        tool: decision.tool, result: "执行中", planningSeconds: planningSeconds)
                    runs[id]?.steps.append(step)
                    update(id, .acting, decision.summary)
                    try Task.checkCancellation()
                    let executionStarted = clock.now
                    let result: ToolResult
                    do {
                        result = try await call(decision.tool, arguments)
                    } catch {
                        if let index = runs[id]?.steps.firstIndex(where: { $0.id == step.id }) {
                            runs[id]?.steps[index].executionSeconds = Self.seconds(clock.now - executionStarted)
                        }
                        throw error
                    }
                    if let index = runs[id]?.steps.firstIndex(where: { $0.id == step.id }) {
                        runs[id]?.steps[index].executionSeconds = Self.seconds(clock.now - executionStarted)
                    }
                    try Task.checkCancellation()
                    let resultText = String(Self.text(result).prefix(4_000))
                    if let index = runs[id]?.steps.indices.last { runs[id]?.steps[index].result = resultText }
                    // Never automatically replay an action after an ambiguous
                    // transport or device error.
                    guard !result.isError else { throw AgentError(resultText) }
                    history.append(PhoneAgentHistory(
                        summary: decision.summary, tool: decision.tool,
                        arguments: arguments.filter { $0.key != "device" }, result: resultText))
                    try await Task.sleep(for: settle)
                }
            }
        } catch is CancellationError {
            finishPendingStep(id, "已中止，请检查手机当前画面")
            update(id, .stopped, "已停止，可直接接手操作手机")
        } catch {
            if Task.isCancelled {
                finishPendingStep(id, "已中止，请检查手机当前画面")
                update(id, .stopped, "已停止，可直接接手操作手机")
            } else {
                finishPendingStep(id, "未确认操作结果，已停止")
                update(id, .failed, error.localizedDescription)
            }
        }
        await finish(id)
    }

    private func availableDevice(_ id: String) throws -> DeviceInfo {
        guard !isLocked(id) else { throw AgentError("当前设备已禁止 AI 操作") }
        guard let current = device(id), current.state == .connected else { throw AgentError("手机已断开连接") }
        guard current.capabilities.contains(.screenshot) else { throw AgentError("当前设备不支持读取画面") }
        return current
    }

    private func finish(_ id: String) async {
        // AI ownership is separate from the workspace/pop-out ownership; ending
        // a task keeps a screen the user is watching alive.
        await release(id)
        activeDeviceID = nil
        task = nil
    }

    private func update(_ id: String, _ status: PhoneAgentStatus, _ message: String) {
        runs[id]?.status = status
        runs[id]?.message = message
    }

    private func finishPendingStep(_ id: String, _ result: String) {
        guard let index = runs[id]?.steps.indices.last, runs[id]?.steps[index].result == "执行中" else { return }
        runs[id]?.steps[index].result = result
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    static func text(_ result: ToolResult) -> String {
        result.content.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n")
    }

    /// The built-in assistant is deliberately a screen operator. Device admin,
    /// filesystem and host shell tools remain external MCP features.
    static func scopedTools(_ descriptors: [ToolDescriptor], device: DeviceInfo) -> [ToolDescriptor] {
        let names: Set<String> = [
            "tap", "long_press", "swipe", "scroll", "press_key", "type_text", "fill_text",
            "get_ui_tree", "current_app", "launch_app", "list_apps",
        ]
        return descriptors.filter { names.contains($0.name) && (!["type_text", "fill_text"].contains($0.name) || device.capabilities.contains(.text)) && ($0.name != "fill_text" || device.capabilities.contains(.touch)) }.map { descriptor in
            var descriptor = descriptor
            guard var schema = descriptor.inputSchema.objectValue,
                  var props = schema["properties"]?.objectValue else { return descriptor }
            props["device"] = nil
            if !device.capabilities.contains(.uiTree), ["tap", "long_press", "fill_text"].contains(descriptor.name) {
                props["element"] = nil
                schema["required"] = descriptor.name == "fill_text" ? ["x", "y", "text"] : ["x", "y"]
                descriptor.description = descriptor.name == "fill_text"
                    ? "点按当前截图中的 x、y 输入框坐标，等待焦点后一次输入完整 text，不回车、不发送。iPhone USB 限 1–8192 UTF-8 字节。"
                    : "通过当前截图中的 x、y 坐标" + (descriptor.name == "tap" ? "点按。" : "长按。")
            }
            if device.platform == .ios, device.connection == .usb, descriptor.name == "press_key" {
                props["key"] = ["type": "string", "enum": ["home", "enter", "delete", "tab", "up", "down", "left", "right"], "description": "USB 支持的主页键与键盘按键"]
            }
            if device.platform == .ios, device.connection == .usb,
               device.capabilities.contains(.text), descriptor.name == "type_text" {
                descriptor.description = "先聚焦输入框，再通过原生 USB 粘贴 UTF-8 文本（1–8192 字节）；默认只输入，不提交或发送。需要发送时观察画面后单独操作。"
            }
            schema["properties"] = .object(props)
            descriptor.inputSchema = .object(schema)
            return descriptor
        }
    }

    static func validatedArguments(
        _ decision: PhoneAgentDecision, tools: [ToolDescriptor], screenSize: (width: Int, height: Int)? = nil
    ) throws -> [String: JSONValue] {
        guard let tool = tools.first(where: { $0.name == decision.tool }),
              decision.argumentsJSON.utf8.count <= 16_384,
              let args = try JSONDecoder().decode(JSONValue.self, from: Data(decision.argumentsJSON.utf8)).objectValue,
              let props = tool.inputSchema["properties"]?.objectValue,
              args.keys.allSatisfy({ $0 != "device" && props[$0] != nil }) else {
            throw AgentError("模型请求了当前设备不支持的操作或参数，已停止")
        }
        if case .array(let required) = tool.inputSchema["required"] {
            guard required.allSatisfy({ $0.stringValue.map { args[$0] != nil && args[$0] != .null } ?? false }) else {
                throw AgentError("模型操作缺少必填参数，已停止")
            }
        }
        for (name, value) in args {
            if case .array(let values) = props[name]?["enum"], !values.contains(value) {
                throw AgentError("模型请求了当前设备不支持的 \(name)，已停止")
            }
            if let size = screenSize, ["x", "x1", "x2", "y", "y1", "y2"].contains(name) {
                let limit = name.hasPrefix("x") ? size.width : size.height
                guard let coordinate = value.doubleValue, coordinate.isFinite,
                      coordinate >= 0, coordinate < Double(limit) else {
                    throw AgentError("模型给出的触控坐标超出当前画面，已停止")
                }
            }
        }
        return args
    }

    struct AgentError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
