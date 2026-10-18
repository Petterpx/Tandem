import Testing
import Foundation
import os
import ControlProtocol
@testable import MCPBridge

// MARK: - 测试工具

/// 按顺序取出放入的值；超时仍等不到返回 nil，回归时测试失败而不是挂住。
private actor Mailbox<T: Sendable> {
    private var queue: [T] = []
    private var waiter: (token: Int, cont: CheckedContinuation<T?, Never>)?
    private var tokens = 0
    private var ended = false

    func put(_ value: T) {
        if let w = waiter {
            waiter = nil
            w.cont.resume(returning: value)
        } else {
            queue.append(value)
        }
    }

    func finish() {
        ended = true
        if let w = waiter {
            waiter = nil
            w.cont.resume(returning: nil)
        }
    }

    func next(timeout: Duration = .seconds(2)) async -> T? {
        if !queue.isEmpty { return queue.removeFirst() }
        if ended { return nil }
        tokens += 1
        let token = tokens
        return await withCheckedContinuation { cont in
            waiter = (token, cont)
            Task {
                try? await Task.sleep(for: timeout)
                self.expire(token)
            }
        }
    }

    private func expire(_ token: Int) {
        guard let w = waiter, w.token == token else { return }
        waiter = nil
        w.cont.resume(returning: nil)
    }
}

/// 通道的一端：发 RPCMessage；收到的行解码后排进 inbox。
private struct Peer: Sendable {
    let channel: any LineChannel
    let inbox = Mailbox<RPCMessage>()

    init(_ channel: any LineChannel) {
        self.channel = channel
        let inbox = inbox
        Task {
            for await line in channel.incoming {
                if let m = try? LineCodec.decode(line) { await inbox.put(m) }
            }
            await inbox.finish()
        }
    }

    func send(_ m: RPCMessage) throws { try channel.send(LineCodec.encode(m)) }
    func next() async throws -> RPCMessage { try #require(await inbox.next()) }
}

/// 假 App：前 `failures` 次 connect 抛错，之后每次 connect 新建一对内存通道，App 一端放进 `peers`。
private final class FakeApp: Sendable {
    let failures: Int
    let peers = Mailbox<Peer>()
    private let connects = OSAllocatedUnfairLock(initialState: 0)
    private let launches = OSAllocatedUnfairLock(initialState: 0)

    init(failures: Int = 0) { self.failures = failures }

    var connectCount: Int { connects.withLock { $0 } }
    var launchCount: Int { launches.withLock { $0 } }

    func connect() throws -> any LineChannel {
        let n = connects.withLock { c in
            c += 1
            return c
        }
        if n <= failures { throw SocketError.system("connect", ECONNREFUSED) }
        let (bridgeEnd, appEnd) = MemoryChannel.pair()
        let peer = Peer(appEnd)
        Task { await peers.put(peer) }
        return bridgeEnd
    }

    func launch() { launches.withLock { $0 += 1 } }

    /// 取下一条连接并应答 hello，返回该连接与收到的 hello。
    func accept(protocolVersion: Int = ControlProtocolVersion.current) async throws -> (Peer, RPCMessage) {
        let peer = try #require(await peers.next())
        let hello = try await peer.next()
        #expect(hello.method == ControlMethod.hello)
        let result = try JSONValue(encoding: HelloResult(protocolVersion: protocolVersion, appVersion: "test"))
        try peer.send(.response(id: try #require(hello.id), result: result))
        return (peer, hello)
    }
}

private func options(_ app: FakeApp, launchTimeout: Duration = .seconds(2),
                     retryInterval: Duration = .milliseconds(20), helloTimeout: Duration = .seconds(5),
                     callTimeout: Duration = .seconds(90)) -> BridgeOptions {
    BridgeOptions(connect: { try app.connect() }, launchApp: { app.launch() },
                  launchTimeout: launchTimeout, retryInterval: retryInterval,
                  helloTimeout: helloTimeout, callTimeout: callTimeout, serverVersion: "1.2.3")
}

/// 启动 bridge，返回扮演 MCP 客户端的一端。
private func startBridge(_ app: FakeApp, launchTimeout: Duration = .seconds(2),
                         retryInterval: Duration = .milliseconds(20), helloTimeout: Duration = .seconds(5),
                         callTimeout: Duration = .seconds(90)) -> Peer {
    let (clientEnd, bridgeEnd) = MemoryChannel.pair()
    let bridge = MCPBridge(client: bridgeEnd,
                           options: options(app, launchTimeout: launchTimeout, retryInterval: retryInterval,
                                            helloTimeout: helloTimeout, callTimeout: callTimeout))
    Task { await bridge.run() }
    return Peer(clientEnd)
}

private func initialize(_ client: Peer, version: String = "2025-06-18") async throws -> RPCMessage {
    try client.send(.request(id: 0, method: "initialize", params: [
        "protocolVersion": .string(version),
        "capabilities": [:],
        "clientInfo": ["name": "claude-code", "version": "2.0"],
    ]))
    return try await client.next()
}

private func call(_ client: Peer, id: JSONValue, tool: String) throws {
    try client.send(.request(id: id, method: ControlMethod.toolsCall, params: ["name": .string(tool)]))
}

private func toolResult(_ m: RPCMessage) throws -> ToolResult {
    try #require(m.result).decode(ToolResult.self)
}

private func text(_ r: ToolResult) -> String {
    if case .text(let s)? = r.content.first { return s }
    return ""
}

// MARK: - 本地应答

@Test func initializeIsAnsweredWithoutApp() async throws {
    let app = FakeApp(failures: .max)
    let client = startBridge(app)
    defer { client.channel.close() }
    let resp = try await initialize(client)
    #expect(resp.id == 0)
    let result = try #require(resp.result)
    #expect(result["protocolVersion"] == "2025-06-18")
    #expect(result["capabilities"]?["tools"]?["listChanged"] == true)
    #expect(result["serverInfo"]?["name"] == "tandem")
    #expect(result["serverInfo"]?["version"] == "1.2.3")
    #expect(app.connectCount == 0)
}

@Test func unknownProtocolVersionFallsBack() async throws {
    let client = startBridge(FakeApp())
    defer { client.channel.close() }
    let resp = try await initialize(client, version: "1999-01-01")
    #expect(resp.result?["protocolVersion"] == "2025-06-18")
}

@Test func pingIsAnsweredAndNotificationsIgnored() async throws {
    let app = FakeApp(failures: .max)
    let client = startBridge(app)
    defer { client.channel.close() }
    try client.send(.notification(method: "notifications/initialized", params: nil))
    try client.send(.request(id: 7, method: "ping", params: nil))
    // 通知没有应答，下一条就是 ping 的结果
    let resp = try await client.next()
    #expect(resp.id == 7)
    #expect(resp.result == [:])
    #expect(app.connectCount == 0)
}

@Test func unknownMethodReturnsMethodNotFound() async throws {
    let client = startBridge(FakeApp())
    defer { client.channel.close() }
    try client.send(.request(id: 5, method: "foo/bar", params: nil))
    let resp = try await client.next()
    #expect(resp.id == 5)
    #expect(resp.error?.code == RPCError.methodNotFound)
}

// MARK: - 转发

@Test func toolsCallIsForwardedWithOriginalID() async throws {
    let app = FakeApp()
    let client = startBridge(app)
    defer { client.channel.close() }
    _ = try await initialize(client)
    try call(client, id: "abc", tool: "tap")

    let (peer, hello) = try await app.accept()
    let helloParams = try #require(hello.params).decode(HelloParams.self)
    #expect(helloParams.protocolVersion == ControlProtocolVersion.current)
    #expect(helloParams.clientName == "claude-code")
    #expect(helloParams.clientVersion == "2.0")

    let forwarded = try await peer.next()
    #expect(forwarded.method == ControlMethod.toolsCall)
    #expect(forwarded.id?.intValue != nil)
    #expect(forwarded.params == ["name": "tap"])
    let ok = try JSONValue(encoding: ToolResult.text("ok"))
    try peer.send(.response(id: try #require(forwarded.id), result: ok))

    let resp = try await client.next()
    #expect(resp.id == "abc")
    #expect(resp.result == ok)
}

@Test func listChangedIsForwarded() async throws {
    let app = FakeApp()
    let client = startBridge(app)
    defer { client.channel.close() }
    try client.send(.request(id: 1, method: ControlMethod.toolsList, params: nil))
    let (peer, _) = try await app.accept()
    let list = try await peer.next()
    try peer.send(.response(id: try #require(list.id), result: try JSONValue(encoding: ToolsListResult(tools: []))))
    #expect(try await client.next().id == 1)

    try peer.send(.notification(method: ControlMethod.toolsListChanged, params: nil))
    let note = try await client.next()
    #expect(note.method == "notifications/tools/list_changed")
    #expect(note.id == nil)
}

@Test func concurrentCallsResolveIndependently() async throws {
    let app = FakeApp()
    let client = startBridge(app)
    defer { client.channel.close() }
    try call(client, id: 1, tool: "wait_for")
    try call(client, id: 2, tool: "tap")
    let (peer, _) = try await app.accept()
    // 两个请求在各自的 Task 里转发，到达顺序不固定，按工具名区分
    let a = try await peer.next()
    let b = try await peer.next()
    let (waitFor, tap) = a.params?["name"] == "wait_for" ? (a, b) : (b, a)
    #expect(tap.params?["name"] == "tap")

    try peer.send(.response(id: try #require(tap.id), result: try JSONValue(encoding: ToolResult.text("tapped"))))
    let first = try await client.next()
    #expect(first.id == 2)
    #expect(text(try toolResult(first)) == "tapped")

    try peer.send(.response(id: try #require(waitFor.id), result: try JSONValue(encoding: ToolResult.text("waited"))))
    let second = try await client.next()
    #expect(second.id == 1)
    #expect(text(try toolResult(second)) == "waited")
}

// MARK: - 连接建立与失败

@Test func launchesAppWhenConnectFails() async throws {
    let app = FakeApp(failures: 2)
    let client = startBridge(app)
    defer { client.channel.close() }
    try client.send(.request(id: 1, method: ControlMethod.toolsList, params: nil))
    let (peer, _) = try await app.accept()
    let list = try await peer.next()
    let tools = ToolsListResult(tools: [ToolDescriptor(name: "tap", description: "点击", inputSchema: [:])])
    try peer.send(.response(id: try #require(list.id), result: try JSONValue(encoding: tools)))

    let resp = try await client.next()
    #expect(resp.id == 1)
    #expect(try #require(resp.result).decode(ToolsListResult.self) == tools)
    #expect(app.launchCount == 1)
    #expect(app.connectCount == 3)
}

@Test func launchTimeoutReturnsAppUnavailable() async throws {
    let app = FakeApp(failures: .max)
    let client = startBridge(app, launchTimeout: .milliseconds(300), retryInterval: .milliseconds(50))
    defer { client.channel.close() }
    try call(client, id: 1, tool: "tap")
    let resp = try await client.next()
    #expect(resp.id == 1)
    let result = try toolResult(resp)
    #expect(result.isError)
    #expect(text(result).hasPrefix("APP_UNAVAILABLE: 无法连接 Tandem"))
    #expect(app.launchCount == 1)

    // tools/list 失败时返回 JSON-RPC 错误
    try client.send(.request(id: 2, method: ControlMethod.toolsList, params: nil))
    let list = try await client.next()
    #expect(list.id == 2)
    #expect(list.error == RPCError(code: RPCError.serverError, message: "无法连接 Tandem"))
}

@Test func versionMismatchFails() async throws {
    let app = FakeApp()
    let client = startBridge(app)
    defer { client.channel.close() }
    try call(client, id: 1, tool: "tap")
    let (peer, _) = try await app.accept(protocolVersion: 99)
    let result = try toolResult(try await client.next())
    #expect(result.isError)
    #expect(text(result).contains("版本"))
    // 握手失败的连接被关闭
    #expect(await peer.inbox.next() == nil)
}

@Test func linkDropFailsPendingAndReconnects() async throws {
    let app = FakeApp()
    let client = startBridge(app)
    defer { client.channel.close() }
    try call(client, id: 1, tool: "tap")
    let (peer, _) = try await app.accept()
    _ = try await peer.next()
    peer.channel.close()
    let dropped = try toolResult(try await client.next())
    #expect(dropped.isError)
    #expect(text(dropped).hasPrefix("APP_UNAVAILABLE"))

    try call(client, id: 2, tool: "tap")
    let (peer2, _) = try await app.accept()
    let forwarded = try await peer2.next()
    try peer2.send(.response(id: try #require(forwarded.id), result: try JSONValue(encoding: ToolResult.text("ok"))))
    let resp = try await client.next()
    #expect(resp.id == 2)
    #expect(try toolResult(resp) == .text("ok"))
    #expect(app.connectCount == 2)
}

@Test func runReturnsWhenClientCloses() async throws {
    let (clientEnd, bridgeEnd) = MemoryChannel.pair()
    let bridge = MCPBridge(client: bridgeEnd, options: options(FakeApp()))
    let done = Mailbox<Bool>()
    Task {
        await bridge.run()
        await done.put(true)
    }
    clientEnd.close()
    #expect(await done.next() == true)
}

@Test func parseErrorRepliesWithExplicitNullID() async throws {
    let (clientEnd, bridgeEnd) = MemoryChannel.pair()
    let bridge = MCPBridge(client: bridgeEnd, options: options(FakeApp()))
    Task { await bridge.run() }
    defer { clientEnd.close() }
    let lines = Mailbox<Data>()
    Task { for await line in clientEnd.incoming { await lines.put(line) } }
    try clientEnd.send(Data("{oops".utf8))
    let line = try #require(await lines.next())
    let object = try #require(try JSONSerialization.jsonObject(with: line) as? [String: Any])
    // JSON-RPC 要求无法解析时 id 为 null，不能省略
    #expect(object["id"] is NSNull)
    #expect((object["error"] as? [String: Any])?["code"] as? Int == RPCError.parseError)
}

@Test func helloWithoutReplyTimesOut() async throws {
    let app = FakeApp()
    let client = startBridge(app, helloTimeout: .milliseconds(200))
    defer { client.channel.close() }
    let start = ContinuousClock.now
    try call(client, id: 1, tool: "tap")
    // App 收下连接与 hello 但不应答（卡住）
    let peer = try #require(await app.peers.next())
    #expect(try await peer.next().method == ControlMethod.hello)
    let result = try toolResult(try await client.next())
    #expect(result.isError && text(result).hasPrefix("APP_UNAVAILABLE: 无法连接 Tandem"))
    #expect(ContinuousClock.now - start < .seconds(1))
    // 握手超时的连接被关闭
    #expect(await peer.inbox.next() == nil)
}

@Test func forwardedCallWithoutReplyTimesOut() async throws {
    let app = FakeApp()
    let client = startBridge(app, callTimeout: .milliseconds(200))
    defer { client.channel.close() }
    try call(client, id: 1, tool: "tap")
    let (peer, _) = try await app.accept()
    _ = try await peer.next()
    let resp = try await client.next()
    #expect(resp.id == 1)
    let result = try toolResult(resp)
    #expect(result.isError && text(result).hasPrefix("APP_UNAVAILABLE: Tandem 无响应"))
}
