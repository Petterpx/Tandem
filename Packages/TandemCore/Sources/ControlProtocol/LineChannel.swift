import Foundation
import os

/// 按行收发的双向通道（App 控制服务与 tandem-mcp 之间、MCP 客户端与 tandem-mcp 之间）。
public protocol LineChannel: AnyObject, Sendable {
    /// 每个元素是一行（不含换行）；对端关闭或本端 `close()` 后结束。
    var incoming: AsyncStream<Data> { get }
    /// 发送一行，自动补换行；并发调用安全。
    func send(_ line: Data) throws
    func close()
}

/// 内存中的一对通道，测试用：一端 send，另一端 incoming 收到；任一端 close 后两端都结束。
public final class MemoryChannel: LineChannel {
    /// 两端共享的状态；`continuations[i]` 是第 i 端的 incoming。
    private final class Link: Sendable {
        let continuations: [AsyncStream<Data>.Continuation]
        let closed = OSAllocatedUnfairLock(initialState: false)
        init(_ continuations: [AsyncStream<Data>.Continuation]) { self.continuations = continuations }
    }

    public let incoming: AsyncStream<Data>
    private let link: Link
    private let side: Int

    private init(incoming: AsyncStream<Data>, link: Link, side: Int) {
        self.incoming = incoming
        self.link = link
        self.side = side
    }

    public static func pair() -> (MemoryChannel, MemoryChannel) {
        let (s0, c0) = AsyncStream<Data>.makeStream()
        let (s1, c1) = AsyncStream<Data>.makeStream()
        let link = Link([c0, c1])
        return (MemoryChannel(incoming: s0, link: link, side: 0), MemoryChannel(incoming: s1, link: link, side: 1))
    }

    public func send(_ line: Data) throws {
        // 在锁内 yield：保证 close 之后不会再有数据进入对端，且并发 send 各自整行送达。
        try link.closed.withLock { closed in
            guard !closed else { throw SocketError.closed }
            link.continuations[1 - side].yield(line)
        }
    }

    public func close() {
        let first = link.closed.withLock { closed in
            defer { closed = true }
            return !closed
        }
        guard first else { return }
        link.continuations.forEach { $0.finish() }
    }
}
