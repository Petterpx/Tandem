import ControlProtocol
import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct ToolRegistryTests {
    private static let allNames = [
        "list_devices", "screenshot", "get_ui_tree", "wait_for", "tap", "long_press", "swipe", "scroll",
        "type_text", "press_key", "get_clipboard", "set_clipboard",
    ]

    /// AIEnv 的闭包是 unowned，测试期间必须持有。
    private let env = AIEnv()

    private func text(_ r: ToolResult) -> String {
        guard case .text(let t) = r.content.first else { return "" }
        return t
    }

    @Test func allToolsWhenNoDevice() {
        let r = ToolRegistry(commands: env.commands)
        #expect(r.descriptors(for: []).map(\.name) == Self.allNames)
    }

    @Test func filteredByCapabilityUnion() {
        let r = ToolRegistry(commands: env.commands)
        var d = AIEnv.pixel
        d.capabilities = [.screenshot]
        #expect(r.descriptors(for: [d]).map(\.name) == ["list_devices", "screenshot"])
        d.state = .offline
        #expect(r.descriptors(for: [d]).count == 12)
    }

    @Test func everySchemaIsObjectWithDevice() {
        let r = ToolRegistry(commands: env.commands)
        for t in r.descriptors(for: []) {
            #expect(t.inputSchema["type"]?.stringValue == "object")
            #expect(t.inputSchema["additionalProperties"] == false)
            let hasDevice = t.inputSchema["properties"]?["device"] != nil
            #expect(hasDevice == (t.name != "list_devices"))
            #expect(t.inputSchema["required"]?.objectValue == nil)
            if case .array(let req) = t.inputSchema["required"] { #expect(!req.contains("device")) }
        }
    }

    @Test func unknownToolThrowsRPCError() async {
        let r = ToolRegistry(commands: env.commands)
        do {
            _ = try await r.call("nope", arguments: [:])
            Issue.record("应抛错")
        } catch {
            // 测试 bundle 与 App 各带一份 ControlProtocol 时 `as RPCError` 的类型转换会失败，改比较描述
            #expect("\(error)" == "\(RPCError(code: RPCError.invalidParams, message: "未知工具：nope"))")
            #expect(RPCError.invalidParams == -32602)
        }
    }

    @Test func tapNeedsPointOrElement() async throws {
        let r = ToolRegistry(commands: env.commands)
        for args: [String: JSONValue] in [["x": 1], [:], ["x": 1, "y": 2, "element": 3], ["element": ""], ["element": true]] {
            let result = try await r.call("tap", arguments: args)
            #expect(result.isError && text(result).hasPrefix("INVALID_ARGUMENT:"))
        }
    }

    @Test func tapByPointSucceeds() async throws {
        let e = AIEnv()
        e.states[AIEnv.pixel.id] = .running(width: 1080, height: 2400)
        let result = try await ToolRegistry(commands: e.commands).call("tap", arguments: ["x": 640, "y": 100])
        withExtendedLifetime(e) {}
        #expect(!result.isError && text(result).hasPrefix("已点击"))
    }

    @Test func waitForArguments() async throws {
        let r = ToolRegistry(commands: env.commands)
        for args: [String: JSONValue] in [["text": "a", "timeout": 61], ["id": "x", "timeout": 0], [:], ["text": ""], ["id": ""]] {
            let result = try await r.call("wait_for", arguments: args)
            #expect(result.isError && text(result).hasPrefix("INVALID_ARGUMENT:"))
        }
        #expect(ToolRegistry.timeout(for: "wait_for", arguments: ["timeout": 20]) == .seconds(25))
        #expect(ToolRegistry.timeout(for: "wait_for", arguments: [:]) == .seconds(15))
        #expect(ToolRegistry.timeout(for: "tap", arguments: [:]) == .seconds(30))
    }

    @Test func rangesAndRequired() async throws {
        let r = ToolRegistry(commands: env.commands)
        let cases: [(String, [String: JSONValue])] = [
            ("long_press", ["x": 1, "y": 1, "duration_ms": 0]),
            ("long_press", ["x": 1, "y": 1, "duration_ms": 10001]),
            ("swipe", ["x1": 1, "y1": 1, "x2": 2, "y2": 2, "duration_ms": 5001]),
            ("swipe", ["x1": 1]),
            ("scroll", ["direction": "sideways"]),
            ("press_key", ["key": "x"]), ("type_text", ["text": ""]), ("type_text", ["text": 3]),
            ("set_clipboard", [:]), ("screenshot", ["hq": "yes"]),
        ]
        for (name, args) in cases {
            let result = try await r.call(name, arguments: args)
            #expect(result.isError && text(result).hasPrefix("INVALID_ARGUMENT:"), "\(name) \(args)")
        }
    }

    @Test func screenshotReturnsImageAndSize() async throws {
        let e = AIEnv(actions: FakeActions(result: .success(AIEnv.png(width: 540, height: 1200))), hasSession: false)
        let result = try await ToolRegistry(commands: e.commands).call("screenshot", arguments: [:])
        withExtendedLifetime(e) {}
        guard case .image(_, let mime) = result.content[0], case .text(let t) = result.content[1] else {
            Issue.record("应为图片加文字")
            return
        }
        #expect(mime == "image/png" && t.hasPrefix("576x1280") && t.contains("screencap"))
    }

    @Test func lockedIsFormatted() async throws {
        let e = AIEnv()
        e.locks.setLocked(AIEnv.pixel.id, true)
        let result = try await ToolRegistry(commands: e.commands).call("tap", arguments: ["x": 1, "y": 1])
        withExtendedLifetime(e) {}
        #expect(result.isError)
        #expect(text(result) == "AI_LOCKED: 设备已锁定，禁止 AI 操作。建议：请在 Tandem 的「AI」标签中关闭「禁止 AI 操作」")
    }

    @Test func unsupportedCapability() async throws {
        var d = AIEnv.pixel
        d.capabilities = [.screenshot]
        let e = AIEnv(devices: [d])
        let result = try await ToolRegistry(commands: e.commands).call("get_ui_tree", arguments: [:])
        withExtendedLifetime(e) {}
        #expect(result.isError && text(result) == "UNSUPPORTED: 该设备不支持 get_ui_tree")
    }

    @Test func listDevicesIncludesTools() async throws {
        let result = try await ToolRegistry(commands: env.commands).call("list_devices", arguments: [:])
        #expect(text(result).contains("\n  工具：screenshot, get_ui_tree, wait_for"))
        #expect(!text(result).contains("工具：list_devices"))
        let none = AIEnv(devices: [])
        let empty = try await ToolRegistry(commands: none.commands).call("list_devices", arguments: [:])
        withExtendedLifetime(none) {}
        #expect(text(empty) == "没有发现设备")
    }

    @Test func deviceErrorsAreResults() async throws {
        let none = AIEnv(devices: [])
        let result = try await ToolRegistry(commands: none.commands).call("screenshot", arguments: [:])
        withExtendedLifetime(none) {}
        #expect(result.isError && text(result).hasPrefix("DEVICE_NOT_FOUND:"))
        let bad = try await ToolRegistry(commands: env.commands).call("screenshot", arguments: ["device": 5])
        #expect(bad.isError && text(bad).hasPrefix("INVALID_ARGUMENT:"))
    }
}
