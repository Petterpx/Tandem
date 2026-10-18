import Foundation
import Network
import Testing
import DeviceCore
@testable import AndroidDriver

/// 本地回环：不需要设备。
struct TCPByteStreamTests {
    private final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    /// 起一个只收 5 字节、原样回写后关闭的回环服务端。
    private func startEchoListener() async throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)  // 只监听回环
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            conn.receive(minimumIncompleteLength: 5, maximumLength: 5) { data, _, _, _ in
                // finalMessage 会发出 FIN，客户端随后读到 EOF。
                conn.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
            }
        }
        let resumed = Box(false)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready where !resumed.value: resumed.value = true; c.resume()
                case .failed(let e) where !resumed.value: resumed.value = true; c.resume(throwing: e)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "test.listener"))
        }
        return listener
    }

    @Test func roundTripsAndReportsEOF() async throws {
        let listener = try await startEchoListener()
        defer { listener.cancel() }
        let port = try #require(listener.port?.rawValue)

        let stream = try await TCPByteStream.connect(port: port)
        try await stream.write(Data("hello".utf8))
        #expect(try await stream.readExactly(2) == Data("he".utf8))
        #expect(try await stream.readExactly(3) == Data("llo".utf8))
        await #expect(throws: ByteStreamError.closed) { _ = try await stream.readExactly(1) }
        stream.close()
    }

    @Test func connectionRefusedFails() async {
        // 回环上的 1 号端口（tcpmux）不会有服务监听：拒绝连接时应立即失败，而不是停在 waiting。
        let error = await #expect(throws: DeviceError.self) { _ = try await TCPByteStream.connect(port: 1) }
        #expect(error?.code == .CONNECTION_FAILED)
    }
}
