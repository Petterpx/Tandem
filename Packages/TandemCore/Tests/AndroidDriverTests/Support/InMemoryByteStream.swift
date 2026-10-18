import Foundation
@testable import AndroidDriver

/// 内存里的双向流：会话一端用 `ByteStream` 读写；测试一端 `feed`/`finish` 喂数据，并读取会话写出的字节。
final class InMemoryByteStream: ByteStream, @unchecked Sendable {
    private struct PendingRead {
        var count: Int
        var continuation: CheckedContinuation<Data, any Error>
    }

    private let lock = NSLock()
    private var incoming = Data()
    private var outgoing = Data()
    private var finished = false
    private var closed = false
    private var pending: PendingRead?
    private var _writeDelay: (@Sendable () -> Duration)?
    private var inFlightWrites = 0
    private var _maxInFlightWrites = 0

    init(_ initial: Data = Data()) {
        incoming = initial
    }

    // MARK: 测试端

    /// 会话写出的全部字节。
    var written: Data { lock.withLock { outgoing } }
    var isClosed: Bool { lock.withLock { closed } }
    /// 每次 write 落盘前先挂起这么久（模拟异步 socket 写），用于暴露并发写乱序。
    var writeDelay: (@Sendable () -> Duration)? {
        get { lock.withLock { _writeDelay } }
        set { lock.withLock { _writeDelay = newValue } }
    }
    /// 同时进行中的 write 的最大数量。
    var maxInFlightWrites: Int { lock.withLock { _maxInFlightWrites } }

    func feed(_ data: Data) {
        let resume: (CheckedContinuation<Data, any Error>, Data)? = lock.withLock {
            incoming.append(data)
            return takePendingIfSatisfiable()
        }
        resume.map { $0.0.resume(returning: $0.1) }
    }

    func feed(_ bytes: [UInt8]) { feed(Data(bytes)) }

    /// 模拟对端关闭：缓冲读完后读取抛 `ByteStreamError.closed`。
    func finish() {
        let pendingRead: PendingRead? = lock.withLock {
            finished = true
            defer { pending = nil }
            return pending
        }
        pendingRead?.continuation.resume(throwing: ByteStreamError.closed)
    }

    /// 等会话写出至少 `count` 字节（有上限的轮询）。
    func waitForWritten(atLeast count: Int, timeout: Duration = .seconds(2)) async -> Data {
        let deadline = ContinuousClock.now + timeout
        while written.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        return written
    }

    // MARK: ByteStream

    func readExactly(_ n: Int) async throws -> Data {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                let result: Result<Data, any Error>? = lock.withLock {
                    if incoming.count >= n {
                        let chunk = Data(incoming.prefix(n))
                        incoming.removeFirst(n)
                        return .success(chunk)
                    }
                    if finished || closed || Task.isCancelled { return .failure(ByteStreamError.closed) }
                    precondition(pending == nil, "InMemoryByteStream 只支持一个读者")
                    pending = PendingRead(count: n, continuation: continuation)
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            let pendingRead: PendingRead? = lock.withLock {
                defer { pending = nil }
                return pending
            }
            pendingRead?.continuation.resume(throwing: CancellationError())
        }
    }

    func write(_ data: Data) async throws {
        let delay: Duration? = lock.withLock {
            inFlightWrites += 1
            _maxInFlightWrites = max(_maxInFlightWrites, inFlightWrites)
            return _writeDelay?()
        }
        defer { lock.withLock { inFlightWrites -= 1 } }
        if let delay { try? await Task.sleep(for: delay) }
        try lock.withLock {
            if closed { throw ByteStreamError.closed }
            outgoing.append(data)
        }
    }

    func close() {
        let pendingRead: PendingRead? = lock.withLock {
            closed = true
            defer { pending = nil }
            return pending
        }
        pendingRead?.continuation.resume(throwing: ByteStreamError.closed)
    }

    /// 调用方需持有 lock。
    private func takePendingIfSatisfiable() -> (CheckedContinuation<Data, any Error>, Data)? {
        guard let p = pending, incoming.count >= p.count else { return nil }
        pending = nil
        let chunk = Data(incoming.prefix(p.count))
        incoming.removeFirst(p.count)
        return (p.continuation, chunk)
    }
}
