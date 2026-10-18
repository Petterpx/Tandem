import ControlProtocol
import DeviceCore
import Foundation

/// MCP 工具表：名称、描述、Schema、所需能力与参数解析，把 tools/call 的参数转成 AICommands 调用。
@MainActor
final class ToolRegistry {
    private struct Tool {
        let name: String
        let description: String
        let properties: [String: JSONValue]
        let required: [String]
        let capability: Capability?
        /// list_devices 没有 device 参数，由 call 单独处理。
        let run: (@MainActor (ToolArguments, DeviceInfo) async throws -> ToolResult)?

        var descriptor: ToolDescriptor {
            var props = properties
            if run != nil { props["device"] = ToolRegistry.deviceProperty }
            return ToolDescriptor(
                name: name, description: description,
                inputSchema: .object([
                    "type": "object", "properties": .object(props),
                    "required": .array(required.map { .string($0) }), "additionalProperties": false,
                ]))
        }
    }

    private nonisolated static let deviceProperty: JSONValue = [
        "type": "string", "description": "设备 id、serial 或名称；只连接一台时可省略",
    ]
    private static let space = "坐标空间：设备当前方向，长边 1280，与 screenshot 图片像素一致。"
    private static let keys = [
        "back", "home", "recents", "enter", "delete", "tab", "up", "down", "left", "right",
        "volume_up", "volume_down", "power",
    ]

    private static func number(_ description: String) -> JSONValue { ["type": "number", "description": .string(description)] }
    private static func integer(_ description: String) -> JSONValue { ["type": "integer", "description": .string(description)] }
    private static func string(_ description: String) -> JSONValue { ["type": "string", "description": .string(description)] }
    private static func boolean(_ description: String) -> JSONValue { ["type": "boolean", "description": .string(description)] }

    private let commands: AICommands
    private var tools: [Tool] = []

    init(commands: AICommands) {
        self.commands = commands
        tools = makeTools()
    }

    // MARK: 工具列表

    /// 已连接设备能力并集所需的工具，加上 list_devices；没有已连接设备时返回全部。
    func descriptors(for devices: [DeviceInfo]) -> [ToolDescriptor] {
        let connected = devices.filter { $0.state == .connected }
        guard !connected.isEmpty else { return tools.map(\.descriptor) }
        let union = connected.reduce(into: Set<Capability>()) { $0.formUnion($1.capabilities) }
        return tools.filter { $0.run == nil || $0.capability.map(union.contains) ?? true }.map(\.descriptor)
    }

    /// 单台设备可用的工具名（不含 list_devices）。
    private func toolNames(for device: DeviceInfo) -> [String] {
        tools.filter { $0.run != nil && ($0.capability.map(device.capabilities.contains) ?? true) }.map(\.name)
    }

    /// 调用超时：wait_for 为其 timeout 加 5 秒，其余 30 秒。
    static func timeout(for name: String, arguments: [String: JSONValue]) -> Duration {
        guard name == "wait_for" else { return .seconds(30) }
        // 只采用合法范围内的值，防止超大或负数的 timeout 让 Duration 溢出
        let timeout = arguments["timeout"]?.doubleValue.flatMap { $0 > 0 && $0 <= 60 ? $0 : nil } ?? 10
        return .seconds(timeout + 5)
    }

    // MARK: 调用

    func call(_ name: String, arguments: [String: JSONValue]) async throws -> ToolResult {
        guard let tool = tools.first(where: { $0.name == name }) else {
            throw RPCError(code: RPCError.invalidParams, message: "未知工具：\(name)")
        }
        do {
            let args = ToolArguments(arguments)
            guard let run = tool.run else {
                return .text(commands.listDevices(tools: { toolNames(for: $0) }))
            }
            let device = try commands.resolve(try args.string("device"))
            if let capability = tool.capability, !device.capabilities.contains(capability) {
                throw DeviceError(code: .UNSUPPORTED, message: "该设备不支持 \(name)")
            }
            return try await run(args, device)
        } catch let e as DeviceError {
            return .failure(code: e.code.rawValue, message: e.message, suggestion: e.suggestion)
        } catch {
            return .failure(code: "INTERNAL_ERROR", message: String(describing: error), suggestion: nil)
        }
    }

    // MARK: 工具表

    private func makeTools() -> [Tool] {
        let c = commands
        let space = Self.space
        return [
            Tool(
                name: "list_devices", description: "列出所有设备：id、名称、系统、连接方式、状态、是否投屏中、是否禁止 AI、可用工具。",
                properties: [:], required: [], capability: nil, run: nil),
            Tool(
                name: "screenshot",
                description: "截取设备屏幕，返回图片和一行尺寸、来源说明。" + space + "默认使用最新投屏帧（JPEG）；hq 为 true 或未投屏时用系统截图（PNG）。",
                properties: ["hq": Self.boolean("是否强制使用高清系统截图，默认 false")],
                required: [], capability: .screenshot,
                run: { a, d in
                    let (output, source) = try await c.screenshot(d, hq: try a.bool("hq") ?? false)
                    return ToolResult(content: [
                        .image(data: output.data, mimeType: output.mimeType),
                        .text("\(output.width)x\(output.height)，来源：\(source)"),
                    ])
                }),
            Tool(
                name: "get_ui_tree",
                description: "读取界面元素，一行一个，如 [12] Button \"登录\" id=login_btn (540,1820)，坐标为元素中心。" + space
                    + "结果会按设备缓存，供 tap 与 long_press 的 element 序号使用。默认只列可交互或有文字的元素。",
                properties: ["all": Self.boolean("是否列出全部元素，默认 false")],
                required: [], capability: .uiTree,
                run: { a, d in .text(try await c.uiTree(d, all: try a.bool("all") ?? false)) }),
            Tool(
                name: "wait_for",
                description: "反复读取界面直到出现匹配的可见元素，返回该元素一行并更新缓存；超时返回 TIMEOUT。text 与 id 至少给一个。",
                properties: [
                    "text": Self.string("元素文字或 content-desc"), "id": Self.string("元素 resource id"),
                    "timeout": Self.number("等待秒数，大于 0 且不超过 60，默认 10"),
                ],
                required: [], capability: .uiTree,
                run: { a, d in
                    let text = try a.nonEmptyString("text"), id = try a.nonEmptyString("id")
                    guard text != nil || id != nil else {
                        throw DeviceError(code: .INVALID_ARGUMENT, message: "参数 text 与 id 至少提供一个")
                    }
                    let timeout = try a.double("timeout") ?? 10
                    guard timeout > 0, timeout <= 60 else {
                        throw DeviceError(code: .INVALID_ARGUMENT, message: "参数 timeout 须大于 0 且不超过 60 秒")
                    }
                    return .text(try await c.waitFor(d, text: text, id: id, timeout: .seconds(timeout)))
                }),
            Tool(
                name: "tap",
                description: "点按。用 x、y 指定坐标，或用 element 指定元素（序号取自最近一次 get_ui_tree / wait_for，字符串按文字匹配）。" + space,
                properties: Self.targetProperties(),
                required: [], capability: .touch,
                run: { a, d in .text(try await c.tap(d, try Self.target(a))) }),
            Tool(
                name: "long_press",
                description: "长按。目标指定方式同 tap。" + space,
                properties: Self.targetProperties().merging(
                    ["duration_ms": Self.integer("按住毫秒数，1 到 10000，默认 800")]) { $1 },
                required: [], capability: .touch,
                run: { a, d in
                    let target = try Self.target(a)
                    return .text(
                        try await c.longPress(d, target, durationMs: try a.int("duration_ms", in: 1...10000, default: 800)))
                }),
            Tool(
                name: "swipe", description: "从起点滑到终点。" + space,
                properties: [
                    "x1": Self.number("起点 x。" + space), "y1": Self.number("起点 y。" + space),
                    "x2": Self.number("终点 x。" + space), "y2": Self.number("终点 y。" + space), "duration_ms": Self.integer("滑动毫秒数，1 到 5000，默认 300"),
                ],
                required: ["x1", "y1", "x2", "y2"], capability: .touch,
                run: { a, d in
                    let from = (x: try a.requiredDouble("x1"), y: try a.requiredDouble("y1"))
                    let to = (x: try a.requiredDouble("x2"), y: try a.requiredDouble("y2"))
                    return .text(
                        try await c.swipe(d, from: from, to: to, durationMs: try a.int("duration_ms", in: 1...5000, default: 300)))
                }),
            Tool(
                name: "scroll",
                description: "滚动查看某方向的内容（down 表示查看下方内容，手指向上滑），距离为屏幕边长的 60%。" + space,
                properties: [
                    "direction": ["type": "string", "enum": ["up", "down", "left", "right"], "description": "要查看的内容方向"],
                    "x": Self.number("滚动中心 x，默认屏幕中心。" + space), "y": Self.number("滚动中心 y，默认屏幕中心。" + space),
                ],
                required: ["direction"], capability: .touch,
                run: { a, d in
                    let name = try a.requiredString("direction")
                    guard let direction = AICommands.ScrollDirection(rawValue: name) else {
                        throw DeviceError(code: .INVALID_ARGUMENT, message: "参数 direction 应为 up、down、left、right 之一")
                    }
                    return .text(try await c.scroll(d, direction, at: try a.point("x", "y")))
                }),
            Tool(
                name: "type_text",
                description: "在当前焦点输入文字。非 ASCII 文字通过设备剪贴板粘贴，会覆盖设备剪贴板。",
                properties: ["text": Self.string("要输入的文字"), "submit": Self.boolean("输入后是否再按一次回车，默认 false")],
                required: ["text"], capability: .text,
                run: { a, d in
                    .text(try await c.typeText(d, try a.requiredNonEmptyString("text"), submit: try a.bool("submit") ?? false))
                }),
            Tool(
                name: "press_key", description: "按下一个按键。",
                properties: ["key": ["type": "string", "enum": .array(Self.keys.map { .string($0) }), "description": "按键名"]],
                required: ["key"], capability: .keys,
                run: { a, d in
                    guard let key = AICommands.deviceKey(named: try a.requiredString("key")) else {
                        throw DeviceError(
                            code: .INVALID_ARGUMENT, message: "参数 key 应为 " + Self.keys.joined(separator: "、") + " 之一")
                    }
                    return .text(try await c.pressKey(d, key))
                }),
            Tool(
                name: "get_clipboard", description: "读取设备剪贴板文本；为空或不是文本时返回超时错误。",
                properties: [:], required: [], capability: .clipboard,
                run: { _, d in .text(try await c.getClipboard(d)) }),
            Tool(
                name: "set_clipboard", description: "写入设备剪贴板，会覆盖原内容并进入剪贴板历史。",
                properties: ["text": Self.string("要写入的文字"), "paste": Self.boolean("写入后是否粘贴，默认 false")],
                required: ["text"], capability: .clipboard,
                run: { a, d in
                    .text(try await c.setClipboard(d, text: try a.requiredString("text"), paste: try a.bool("paste") ?? false))
                }),
        ]
    }

    private static func targetProperties() -> [String: JSONValue] {
        [
            "x": number("点按 x。" + space), "y": number("点按 y。" + space),
            "element": [
                "type": ["integer", "string"],
                "description": "元素序号（最近一次 get_ui_tree / wait_for 的结果）或元素文字；与 x、y 二选一",
            ],
        ]
    }

    /// tap / long_press 的目标：x、y 成对，与 element 二选一。
    private static func target(_ a: ToolArguments) throws -> AICommands.TapTarget {
        let point = try a.point("x", "y")
        let element = a.values["element"].flatMap { $0 == .null ? nil : $0 }
        switch (point, element) {
        case (let p?, nil): return .point(x: p.x, y: p.y)
        case (nil, let e?):
            if let i = e.intValue { return .index(i) }
            guard let s = e.stringValue else {
                throw DeviceError(code: .INVALID_ARGUMENT, message: "参数 element 应为整数序号或字符串")
            }
            guard !s.isEmpty else { throw DeviceError(code: .INVALID_ARGUMENT, message: "参数 element 不能为空") }
            return .text(s)
        case (nil, nil):
            throw DeviceError(code: .INVALID_ARGUMENT, message: "需要提供 x 和 y，或 element")
        default:
            throw DeviceError(code: .INVALID_ARGUMENT, message: "x、y 与 element 只能二选一")
        }
    }
}
