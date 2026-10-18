import Foundation
import ControlProtocol

/// bridge 的外部依赖：连接 App 与拉起 App 都可注入，便于测试。
public struct BridgeOptions: Sendable {
    public var connect: @Sendable () throws -> any LineChannel
    public var launchApp: @Sendable () throws -> Void
    public var launchTimeout: Duration
    public var retryInterval: Duration
    public var serverVersion: String

    public init(connect: @escaping @Sendable () throws -> any LineChannel,
                launchApp: @escaping @Sendable () throws -> Void,
                launchTimeout: Duration = .seconds(15),
                retryInterval: Duration = .milliseconds(500),
                serverVersion: String) {
        self.connect = connect
        self.launchApp = launchApp
        self.launchTimeout = launchTimeout
        self.retryInterval = retryInterval
        self.serverVersion = serverVersion
    }
}

/// MCP 服务端（tandem-mcp 的全部逻辑）：`initialize` / `ping` 本地应答，
/// `tools/list` / `tools/call` 经 `AppLink` 转发给 App。
public actor MCPBridge {
    public static let supportedProtocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]
    public static let fallbackProtocolVersion = "2025-06-18"

    private let client: any LineChannel
    private let link: AppLink
    private let serverVersion: String

    public init(client: any LineChannel, options: BridgeOptions) {
        self.client = client
        serverVersion = options.serverVersion
        link = AppLink(options: options, onListChanged: { [client] in
            Self.send(.notification(method: "notifications/tools/list_changed", params: nil), to: client)
        })
    }

    /// 处理客户端消息，直到 `client.incoming` 结束；返回前关闭与 App 的连接。
    public func run() async {
        for await line in client.incoming {
            guard let message = try? LineCodec.decode(line) else {
                Self.send(.failure(id: nil, error: RPCError(code: RPCError.parseError, message: "无法解析的消息")),
                          to: client)
                continue
            }
            await handle(message)
        }
        await link.close()
    }

    private func handle(_ m: RPCMessage) async {
        // 客户端发来的通知与响应（我们不向客户端发请求）都不需要应答
        guard let id = m.id, let method = m.method else { return }
        switch method {
        case "initialize":
            let info = m.params?["clientInfo"]
            await link.setClient(name: info?["name"]?.stringValue, version: info?["version"]?.stringValue)
            reply(.response(id: id, result: initializeResult(requested: m.params?["protocolVersion"]?.stringValue)))
        case "ping":
            reply(.response(id: id, result: [:]))
        case ControlMethod.toolsList, ControlMethod.toolsCall:
            // 每个请求独立处理：一个 wait_for 在等待时不挡住后面的 tap
            Task { await forward(id: id, method: method, params: m.params) }
        default:
            reply(.failure(id: id, error: RPCError(code: RPCError.methodNotFound, message: "未知方法：\(method)")))
        }
    }

    private func initializeResult(requested: String?) -> JSONValue {
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.fallbackProtocolVersion
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": true]],
            "serverInfo": ["name": "tandem", "version": .string(serverVersion)],
        ]
    }

    /// 转发给 App，App 的响应换回客户端原来的 id；连接失败时 tools/call 返回错误结果，tools/list 返回 JSON-RPC 错误。
    private func forward(id: JSONValue, method: String, params: JSONValue?) async {
        do {
            let response = try await link.request(method: method, params: params)
            if let error = response.error {
                reply(.failure(id: id, error: error))
            } else {
                reply(.response(id: id, result: response.result))
            }
        } catch {
            let failure = error as? LinkFailure ?? .unavailable
            if method == ControlMethod.toolsCall,
               let result = try? JSONValue(encoding: ToolResult.failure(
                   code: "APP_UNAVAILABLE", message: failure.message, suggestion: failure.suggestion)) {
                reply(.response(id: id, result: result))
            } else {
                reply(.failure(id: id, error: RPCError(code: RPCError.serverError, message: failure.message)))
            }
        }
    }

    private func reply(_ m: RPCMessage) { Self.send(m, to: client) }

    /// 客户端已断开时发送失败，忽略即可。
    private static func send(_ m: RPCMessage, to channel: any LineChannel) {
        guard let line = try? LineCodec.encode(m) else { return }
        try? channel.send(line)
    }
}

extension JSONValue {
    /// 经 JSON 编码把 Codable 值转成 JSONValue。
    init<T: Encodable>(encoding value: T) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }
}
