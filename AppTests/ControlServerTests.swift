import ControlProtocol
import DeviceCore
import Foundation
import MCPBridge
import os
import Testing
@testable import Tandem

/// 按行收消息的测试客户端：后台持续读入，按条件等待（超时报错而不是挂起）。
private final class LineClient: Sendable {
    struct Timeout: Error {}

    let channel: any LineChannel
    private let lines = OSAllocatedUnfairLock(initialState: [Data]())

    init(_ channel: any LineChannel) {
        self.channel = channel
        Task { [lines] in
            for await line in channel.incoming { lines.withLock { $0.append(line) } }
        }
    }

    var messages: [RPCMessage] { lines.withLock { $0 }.compactMap { try? LineCodec.decode($0) } }
    var rawLines: [Data] { lines.withLock { $0 } }

    func send(_ m: RPCMessage) throws { try channel.send(LineCodec.encode(m)) }

    /// 发请求并等待同 id 的响应。
    func request(_ id: Int, _ method: String, _ params: JSONValue? = nil) async throws -> RPCMessage {
        try send(.request(id: .number(Double(id)), method: method, params: params))
        return try await first { $0.id == .number(Double(id)) && $0.method == nil }
    }

    func first(timeout: Duration = .seconds(5), _ match: @Sendable (RPCMessage) -> Bool) async throws -> RPCMessage {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if let m = messages.first(where: match) { return m }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw Timeout()
    }
}

@MainActor
@Suite struct ControlServerTests {
    private struct NoLaunch: Error {}

    private static func socketPath() -> String { "/tmp/tdm-\(UUID().uuidString.prefix(8)).sock" }

    /// 真实 ControlServer + 真实 MCPBridge；`client` 是 MCP 客户端一侧（模拟 Claude Code）。
    @MainActor private struct Harness {
        let env: AIEnv
        let server: ControlServer
        let path: String
        let client: LineClient
        let mcp: MemoryChannel

        func close() {
            mcp.close()
            server.stop()
        }
    }

    private func harness(_ env: AIEnv = AIEnv(), callTimeout: Duration? = nil) -> Harness {
        let path = Self.socketPath()
        let server = ControlServer(
            registry: ToolRegistry(commands: env.commands), devices: { [env] in env.devices }, appVersion: "test",
            callTimeout: callTimeout)
        server.start(path: path)
        let (mcp, bridgeSide) = MemoryChannel.pair()
        let bridge = MCPBridge(
            client: bridgeSide,
            options: BridgeOptions(
                connect: { try UnixSocketConnection.connect(path: path) }, launchApp: { throw NoLaunch() },
                launchTimeout: .milliseconds(100), serverVersion: "test"))
        Task { await bridge.run() }
        return Harness(env: env, server: server, path: path, client: LineClient(mcp), mcp: mcp)
    }

    private func initialize(_ h: Harness, name: String = "claude-code") async throws {
        _ = try await h.client.request(
            1, "initialize",
            ["protocolVersion": "2025-06-18", "clientInfo": ["name": .string(name), "version": "1.0"]])
    }

    private func toolResult(_ m: RPCMessage) throws -> ToolResult {
        try JSONDecoder().decode(ToolResult.self, from: JSONEncoder().encode(m.result))
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw LineClient.Timeout() }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func endToEndInitializeListAndCall() async throws {
        let env = AIEnv(actions: FakeActions(result: .success(AIEnv.png(width: 1080, height: 2400))))
        env.states[AIEnv.pixel.id] = .running(width: 1080, height: 2400)
        let h = harness(env)
        defer { h.close() }
        try await initialize(h)
        let list = try await h.client.request(2, "tools/list")
        let names = list.result?["tools"].flatMap { tools -> [String]? in
            guard case .array(let a) = tools else { return nil }
            return a.compactMap { $0["name"]?.stringValue }
        }
        #expect(names?.contains("tap") == true)

        let shot = try toolResult(try await h.client.request(3, "tools/call", ["name": "screenshot", "arguments": [:]]))
        #expect(!shot.isError)
        guard case .image(_, let mime) = shot.content.first else {
            Issue.record("截图结果应以图片开头：\(shot)")
            return
        }
        #expect(mime == "image/png")

        let tap = try toolResult(
            try await h.client.request(4, "tools/call", ["name": "tap", "arguments": ["x": 288, "y": 640]]))
        #expect(!tap.isError)
        #expect(env.fake.sentActions.count == 2)
    }

    @Test func helloRegistersClient() async throws {
        let h = harness()
        defer { h.close() }
        try await initialize(h)
        #expect(h.server.clients.isEmpty)   // initialize 由 tandem-mcp 本地应答，尚未连接 App
        _ = try await h.client.request(2, "tools/list")
        #expect(h.server.clients.map(\.name) == ["claude-code"])
        #expect(h.server.clients.first?.version == "1.0")
        // 客户端退出 → tandem-mcp 关闭到 App 的连接 → 从列表移除
        h.mcp.close()
        try await waitUntil { h.server.clients.isEmpty }
    }

    @Test func listChangedReachesClient() async throws {
        let h = harness()
        defer { h.close() }
        try await initialize(h)
        _ = try await h.client.request(2, "tools/list")
        let isListChanged: (RPCMessage) -> Bool = { $0.method == "notifications/tools/list_changed" }
        var screenshotOnly = AIEnv.pixel
        screenshotOnly.capabilities = [.screenshot]

        h.server.devicesChanged([screenshotOnly])
        try await waitUntil { h.client.messages.filter(isListChanged).count == 1 }
        h.server.devicesChanged([AIEnv.pixel])
        try await waitUntil { h.client.messages.filter(isListChanged).count == 2 }
        // 工具列表不变：不再推送
        h.server.devicesChanged([AIEnv.pixel])
        try await Task.sleep(for: .milliseconds(200))
        #expect(h.client.messages.filter(isListChanged).count == 2)
    }

    @Test func callTimeoutReturnsTimeoutResult() async throws {
        let finished = OSAllocatedUnfairLock(initialState: false)
        let png = AIEnv.png(width: 1080, height: 2400)
        var actions = FakeActions()
        // 截图比超时慢；被取消时 sleep 抛错，不会标记完成
        actions.screenshotProvider = {
            try await Task.sleep(for: .milliseconds(600))
            finished.withLock { $0 = true }
            return png
        }
        let h = harness(AIEnv(actions: actions), callTimeout: .milliseconds(200))
        defer { h.close() }
        try await initialize(h)
        let r = try toolResult(try await h.client.request(2, "tools/call", ["name": "screenshot", "arguments": [:]]))
        #expect(r.isError)
        #expect(r.content == [.text("TIMEOUT: 操作超时。建议：操作可能仍在执行，请先截图确认")])
        #expect(!finished.withLock { $0 })
        // 超时不取消进行中的调用（手势中途取消会让手指停在按下状态），它会自己执行完
        try await waitUntil { finished.withLock { $0 } }
    }

    @Test func parseErrorRepliesWithNullID() async throws {
        let h = harness()
        defer { h.close() }
        let raw = LineClient(try UnixSocketConnection.connect(path: h.path))
        defer { raw.channel.close() }
        try raw.channel.send(Data("{not json".utf8))
        let reply = try await raw.first { $0.error != nil }
        #expect(reply.error?.code == RPCError.parseError)
        let object = try JSONSerialization.jsonObject(with: raw.rawLines[0]) as? [String: Any]
        #expect(object?.keys.contains("id") == true)
        #expect(object?["id"] is NSNull)
    }

    @Test func unknownMethodIsMethodNotFound() async throws {
        let h = harness()
        defer { h.close() }
        let raw = LineClient(try UnixSocketConnection.connect(path: h.path))
        defer { raw.channel.close() }
        let reply = try await raw.request(7, "nope")
        #expect(reply.error?.code == RPCError.methodNotFound)
    }

    @Test func startFailureIsReported() {
        let env = AIEnv()
        let server = ControlServer(registry: ToolRegistry(commands: env.commands), devices: { [] }, appVersion: "test")
        server.start(path: "/tmp/" + String(repeating: "a", count: 115))
        guard case .failed(let message) = server.status else {
            Issue.record("应为 failed：\(server.status)")
            return
        }
        #expect(message.contains("路径"))
    }

    @Test func stopRemovesSocket() {
        let env = AIEnv()
        let path = Self.socketPath()
        let server = ControlServer(registry: ToolRegistry(commands: env.commands), devices: { [] }, appVersion: "test")
        server.start(path: path)
        #expect(server.status == .running)
        #expect(FileManager.default.fileExists(atPath: path))
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(server.status == .stopped)
    }
}
