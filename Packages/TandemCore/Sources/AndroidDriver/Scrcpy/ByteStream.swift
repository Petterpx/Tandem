import DeviceCore
import Foundation
import Network
import os

public enum ByteStreamError: Error, Equatable, Sendable {
    /// 对端关闭（EOF）或本端已 close。
    case closed
}

public protocol ByteStream: Sendable {
    /// 读满 n 字节；EOF 时抛 `ByteStreamError.closed`。
    func readExactly(_ n: Int) async throws -> Data
    func write(_ data: Data) async throws
    func close()
}

/// 基于 Network.framework 的 TCP 流，只连 127.0.0.1（adb forward 隧道）。
public final class TCPByteStream: ByteStream, @unchecked Sendable {
    private static let queue = DispatchQueue(label: "dev.tandem.tcp")
    private let connection: NWConnection

    private init(connection: NWConnection) {
        self.connection = connection
    }

    public static func connect(port: UInt16) async throws -> TCPByteStream {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw DeviceError.connectionFailed("无效端口 \(port)")
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let connection = NWConnection(host: "127.0.0.1", port: nwPort, using: NWParameters(tls: nil, tcp: tcp))
        // cancelled / resumed 在同一把锁下判断：任务已取消时不再 start（否则可能永远等不到状态回调）。
        struct ConnectState { var cancelled = false, resumed = false }
        let lock = OSAllocatedUnfairLock(initialState: ConnectState())
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                @Sendable func finish(_ result: Result<Void, any Error>) {
                    guard lock.withLock({ s in defer { s.resumed = true }; return !s.resumed }) else { return }
                    continuation.resume(with: result)
                }
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        finish(.success(()))
                    case .failed(let error), .waiting(let error):
                        // 本地端口拒绝连接时会进入 waiting，不等它自动重连。
                        connection.cancel()
                        finish(.failure(DeviceError.connectionFailed("127.0.0.1:\(port) \(error)")))
                    case .cancelled:
                        let cancelled = lock.withLock { $0.cancelled }
                        finish(.failure(cancelled ? CancellationError() : ByteStreamError.closed))
                    default:
                        break
                    }
                }
                let alreadyCancelled = lock.withLock { s -> Bool in
                    if s.cancelled || Task.isCancelled {
                        s.cancelled = true
                        return true
                    }
                    connection.start(queue: queue)
                    return false
                }
                if alreadyCancelled {
                    connection.stateUpdateHandler = nil
                    finish(.failure(CancellationError()))
                }
            }
        } onCancel: {
            lock.withLock { $0.cancelled = true }
            connection.cancel()
        }
        return TCPByteStream(connection: connection)
    }

    public func readExactly(_ n: Int) async throws -> Data {
        var out = Data()
        while out.count < n {
            out += try await receive(max: n - out.count)
        }
        return out
    }

    /// 任务取消时关闭连接，挂起的 receive 随之以错误返回。
    private func receive(max: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            try await receiveOnce(max: max)
        } onCancel: { [connection] in
            connection.cancel()
        }
    }

    private func receiveOnce(max: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: max) { data, _, _, error in
                if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    // 没有数据也没有错误：对端已关闭（EOF）。
                    continuation.resume(throwing: ByteStreamError.closed)
                }
            }
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    public func close() {
        connection.cancel()
    }
}
