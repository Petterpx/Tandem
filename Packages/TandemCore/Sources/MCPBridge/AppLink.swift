import Foundation
import ControlProtocol

/// 与 App 的连接失败的原因；转成给 MCP 客户端的错误文字。
struct LinkFailure: Error {
    var message: String
    var suggestion: String

    static let unavailable = LinkFailure(message: "无法连接 Tandem", suggestion: "请确认 Tandem 已安装且能正常打开")
    static let versionMismatch = LinkFailure(message: "Tandem 版本与 tandem-mcp 不一致", suggestion: "请重启 Tandem 与 MCP 客户端")
}

/// 到 App 控制服务的连接：第一次请求时才建立（连不上就拉起 App 并重试），连上后先 hello；
/// 请求用自己的递增整数 id，按 id 把响应交回等待者。连接断开时进行中的请求全部失败，下次请求重新建立。
actor AppLink {
    private let options: BridgeOptions
    private let onListChanged: @Sendable () -> Void
    private var clientName: String?
    private var clientVersion: String?

    /// 当前连接；握手期间就已设置，读循环结束时据此判断是否清空。
    private var channel: (any LineChannel)?
    /// 进行中的建立连接（含握手）；并发请求共用同一次尝试。
    private var connecting: Task<any LineChannel, Error>?
    /// 等待响应的请求，记下所在连接，断开时只让该连接上的请求失败。
    private var pending: [Int: (channel: any LineChannel, continuation: CheckedContinuation<RPCMessage, Error>)] = [:]
    private var nextID = 1
    private var closed = false

    init(options: BridgeOptions, onListChanged: @escaping @Sendable () -> Void) {
        self.options = options
        self.onListChanged = onListChanged
    }

    /// 记下 MCP 客户端名称与版本，hello 时带给 App。
    func setClient(name: String?, version: String?) {
        clientName = name
        clientVersion = version
    }

    /// 发请求并等待 App 的响应；连接失败抛 `LinkFailure`。
    func request(method: String, params: JSONValue?) async throws -> RPCMessage {
        let ch = try await ensureConnected()
        return try await send(method: method, params: params, on: ch)
    }

    /// 关闭连接并停止进行中的建立；之后的请求都失败。
    func close() {
        closed = true
        connecting?.cancel()
        connecting = nil
        if let ch = channel {
            channel = nil
            ch.close()
        }
    }

    private func ensureConnected() async throws -> any LineChannel {
        if closed { throw LinkFailure.unavailable }
        let task: Task<any LineChannel, Error>
        if let connecting {
            task = connecting
        } else if let channel {
            return channel
        } else {
            task = Task { try await establish() }
            connecting = task
        }
        do {
            let ch = try await task.value
            if connecting == task { connecting = nil }
            return ch
        } catch {
            if connecting == task { connecting = nil }
            throw error
        }
    }

    /// 连接并握手。连接一建立就设为当前连接，这样握手期间断开也能由读循环清空。
    private func establish() async throws -> any LineChannel {
        let ch = try await Self.dial(options)
        channel = ch
        Task { await readLoop(ch) }
        do {
            let hello = HelloParams(protocolVersion: ControlProtocolVersion.current,
                                    clientName: clientName, clientVersion: clientVersion)
            let response = try await send(method: ControlMethod.hello, params: try JSONValue(encoding: hello), on: ch)
            guard response.error == nil, let result = try response.result?.decode(HelloResult.self) else {
                throw LinkFailure.unavailable
            }
            guard result.protocolVersion == ControlProtocolVersion.current else { throw LinkFailure.versionMismatch }
            guard !closed else { throw LinkFailure.unavailable }
        } catch {
            if let current = channel, current === ch { channel = nil }
            ch.close()
            failPending(on: ch)
            throw error as? LinkFailure ?? .unavailable
        }
        return ch
    }

    /// 连不上就拉起一次 App，之后每隔 retryInterval 重试，直到 launchTimeout。
    /// 放到 actor 之外执行：拉起 App 会阻塞到 `open` 退出。
    private static func dial(_ options: BridgeOptions) async throws -> any LineChannel {
        let attempt = Task.detached {
            if let ch = try? options.connect() { return ch }
            do { try options.launchApp() } catch { throw LinkFailure.unavailable }
            let deadline = ContinuousClock.now.advanced(by: options.launchTimeout)
            while ContinuousClock.now < deadline {
                do { try await Task.sleep(for: options.retryInterval) } catch { throw LinkFailure.unavailable }
                if let ch = try? options.connect() { return ch }
            }
            throw LinkFailure.unavailable
        }
        return try await withTaskCancellationHandler { try await attempt.value } onCancel: { attempt.cancel() }
    }

    private func send(method: String, params: JSONValue?, on ch: any LineChannel) async throws -> RPCMessage {
        let id = nextID
        nextID += 1
        let line = try LineCodec.encode(.request(id: .number(Double(id)), method: method, params: params))
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = (ch, continuation)
            do {
                try ch.send(line)
            } catch {
                pending.removeValue(forKey: id)?.continuation.resume(throwing: LinkFailure.unavailable)
            }
        }
    }

    private func readLoop(_ ch: any LineChannel) async {
        for await line in ch.incoming {
            guard let m = try? LineCodec.decode(line) else { continue }
            if m.isNotification {
                if m.method == ControlMethod.toolsListChanged { onListChanged() }
            } else if let id = m.id?.intValue, let entry = pending.removeValue(forKey: id) {
                entry.continuation.resume(returning: m)
            }
        }
        // 连接断开：进行中的请求失败，不重放（操作类工具重放可能执行两次）
        if let current = channel, current === ch { channel = nil }
        failPending(on: ch)
    }

    private func failPending(on channel: any LineChannel) {
        for (id, entry) in pending where entry.channel === channel {
            pending.removeValue(forKey: id)
            entry.continuation.resume(throwing: LinkFailure.unavailable)
        }
    }
}
