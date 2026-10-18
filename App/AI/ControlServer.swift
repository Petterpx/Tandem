import ControlProtocol
import DeviceCore
import Foundation
import Observation

/// 已连接的 MCP 客户端（名称来自 hello），供「AI」标签与菜单栏显示。
struct ControlClient: Identifiable, Equatable {
    /// 所在连接的 id。
    let id: UUID
    let name: String
    let version: String?
}

/// App 控制服务（spec §2.3）：监听 Unix socket，一行一条 JSON-RPC。
/// 每个连接一个读循环，同一连接上的请求各在独立 Task 中处理，可并发。
@MainActor @Observable
final class ControlServer {
    enum Status: Equatable {
        case stopped, running
        case failed(String)
    }

    static let timeoutResult = ToolResult.failure(code: "TIMEOUT", message: "操作超时", suggestion: "请检查设备连接后重试")

    private(set) var status: Status = .stopped
    /// 已 hello 的连接，按 hello 先后排列。
    private(set) var clients: [ControlClient] = []

    @ObservationIgnored private let registry: ToolRegistry
    @ObservationIgnored private let devices: () -> [DeviceInfo]
    @ObservationIgnored private let appVersion: String
    /// 非 nil 时（仅测试用）代替 ToolRegistry.timeout。
    @ObservationIgnored private let callTimeout: Duration?
    @ObservationIgnored private var listener: UnixSocketListener?
    @ObservationIgnored private var acceptTask: Task<Void, Never>?
    @ObservationIgnored private var connections: [UUID: UnixSocketConnection] = [:]
    /// 上次通知时（或启动时）的工具名单；名单变化才推送 list_changed。
    @ObservationIgnored private var toolNames: [String]

    init(registry: ToolRegistry, devices: @escaping () -> [DeviceInfo], appVersion: String, callTimeout: Duration? = nil) {
        self.registry = registry
        self.devices = devices
        self.appVersion = appVersion
        self.callTimeout = callTimeout
        toolNames = registry.descriptors(for: devices()).map(\.name)
    }

    /// 开始监听；失败时记下原因（「AI」标签显示），App 其他功能照常。
    func start(path: String) {
        guard listener == nil else { return }
        let listener: UnixSocketListener
        do {
            listener = try UnixSocketListener(path: path)
        } catch {
            status = .failed(error.localizedDescription)
            return
        }
        self.listener = listener
        status = .running
        acceptTask = Task { [weak self] in
            for await connection in listener.connections {
                guard let self else {
                    connection.close()
                    return
                }
                self.accept(connection)
            }
        }
    }

    /// 关闭监听（同时删除 socket 文件）与所有连接；可重复调用。
    func stop() {
        acceptTask?.cancel()
        acceptTask = nil
        listener?.close()
        listener = nil
        let open = Array(connections.values)
        connections = [:]
        open.forEach { $0.close() }
        clients = []
        status = .stopped
    }

    /// 设备列表变化：已连接设备能力并集对应的工具名单变了，就通知所有已 hello 的连接。
    func devicesChanged(_ devices: [DeviceInfo]) {
        let names = registry.descriptors(for: devices).map(\.name)
        guard names != toolNames else { return }
        toolNames = names
        let notification = RPCMessage.notification(method: ControlMethod.toolsListChanged, params: nil)
        for client in clients {
            if let connection = connections[client.id] { Self.send(notification, to: connection) }
        }
    }

    // MARK: 连接

    private func accept(_ connection: UnixSocketConnection) {
        let id = UUID()
        connections[id] = connection
        Task {
            for await line in connection.incoming { receive(line, connection: id, on: connection) }
            disconnected(id)
        }
    }

    private func disconnected(_ id: UUID) {
        connections.removeValue(forKey: id)?.close()
        clients.removeAll { $0.id == id }
    }

    private func receive(_ line: Data, connection: UUID, on channel: UnixSocketConnection) {
        guard let message = try? LineCodec.decode(line) else {
            // JSON-RPC 2.0：无法解析时 id 为 null（显式写出，不省略）
            Self.send(
                .failure(id: .null, error: RPCError(code: RPCError.parseError, message: "无法解析的消息")), to: channel)
            return
        }
        // 客户端发来的通知与响应不需要应答
        guard let id = message.id, let method = message.method else { return }
        Task {
            let reply = await respond(id: id, method: method, params: message.params, connection: connection)
            Self.send(reply, to: channel)
        }
    }

    private func respond(id: JSONValue, method: String, params: JSONValue?, connection: UUID) async -> RPCMessage {
        do {
            switch method {
            case ControlMethod.hello:
                let hello = try Self.decode(HelloParams.self, params)
                // 握手期间连接已断开就不再记录
                if connections[connection] != nil {
                    let client = ControlClient(
                        id: connection, name: hello.clientName ?? "未知客户端", version: hello.clientVersion)
                    if let i = clients.firstIndex(where: { $0.id == connection }) {
                        clients[i] = client
                    } else {
                        clients.append(client)
                    }
                }
                let result = HelloResult(protocolVersion: ControlProtocolVersion.current, appVersion: appVersion)
                return .response(id: id, result: try Self.encode(result))
            case ControlMethod.toolsList:
                return .response(id: id, result: try Self.encode(ToolsListResult(tools: registry.descriptors(for: devices()))))
            case ControlMethod.toolsCall:
                let call = try Self.decode(ToolCallParams.self, params)
                return .response(id: id, result: try Self.encode(try await self.call(call)))
            default:
                return .failure(id: id, error: RPCError(code: RPCError.methodNotFound, message: "未知方法：\(method)"))
            }
        } catch let error as RPCError {
            return .failure(id: id, error: error)
        } catch {
            return .failure(id: id, error: RPCError(code: RPCError.serverError, message: String(describing: error)))
        }
    }

    /// 调用与超时赛跑。超时只是不再等待，不取消进行中的调用：手势中途取消会让手指停在按下状态，
    /// 所以让它自己执行完（结果丢弃）。
    private func call(_ params: ToolCallParams) async throws -> ToolResult {
        let arguments = params.arguments ?? [:]
        let timeout = callTimeout ?? ToolRegistry.timeout(for: params.name, arguments: arguments)
        let registry = registry
        // nil 表示超时
        let (outcomes, sink) = AsyncStream.makeStream(of: Result<ToolResult, any Error>?.self)
        Task {
            do {
                sink.yield(.success(try await registry.call(params.name, arguments: arguments)))
            } catch {
                sink.yield(.failure(error))
            }
        }
        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            sink.yield(nil)
        }
        defer {
            timer.cancel()
            sink.finish()
        }
        for await outcome in outcomes {
            guard let outcome else { return Self.timeoutResult }
            return try outcome.get()
        }
        return Self.timeoutResult
    }

    // MARK: 编解码

    /// 写入放到主线程之外：对端读得慢时阻塞的写不卡住界面。对端已断开时发送失败，忽略即可。
    private nonisolated static func send(_ message: RPCMessage, to channel: UnixSocketConnection) {
        guard let line = try? LineCodec.encode(message) else { return }
        Task.detached { try? channel.send(line) }
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ params: JSONValue?) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: JSONEncoder().encode(params ?? .null))
        } catch {
            throw RPCError(code: RPCError.invalidParams, message: "参数格式错误")
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}
