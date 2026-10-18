import Foundation
import DeviceCore

/// 输入通道：保证触摸/按键/粘贴按产生顺序到达 session。
/// 每次 run（.task）创建新的 stream；被新一轮取代的旧消费者不再转发，
/// 新一轮在旧一轮结束后才开始发送。无消费者时丢弃输入。
final class InputRouter: @unchecked Sendable {
    enum Op: Sendable, Equatable {
        case action(InputAction)
        case paste(String)
    }

    typealias Token = Int

    private let lock = NSLock()
    private var generation = 0
    private var continuation: AsyncStream<Op>.Continuation?
    private var previousDone: AsyncStream<Void>?

    func open() -> (token: Token, stream: AsyncStream<Op>) {
        let (stream, c) = AsyncStream<Op>.makeStream(bufferingPolicy: .unbounded)
        lock.lock()
        generation += 1
        let token = generation
        continuation?.finish()
        continuation = c
        lock.unlock()
        return (token, stream)
    }

    /// 仅当 token 仍是当前一轮时才结束 stream。
    func close(_ token: Token) {
        lock.lock(); defer { lock.unlock() }
        guard token == generation else { return }
        continuation?.finish()
        continuation = nil
    }

    func isCurrent(_ token: Token) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == generation
    }

    func yield(_ op: Op) {
        lock.lock(); defer { lock.unlock() }
        continuation?.yield(op)
    }

    private func swapPreviousDone(_ done: AsyncStream<Void>) -> AsyncStream<Void>? {
        lock.lock(); defer { lock.unlock() }
        let previous = previousDone
        previousDone = done
        return previous
    }

    func run(_ handle: @Sendable (Op) async -> Void) async {
        let (token, stream) = open()
        let (done, doneC) = AsyncStream<Void>.makeStream()
        let previous = swapPreviousDone(done)
        defer { close(token); doneC.finish() }
        if let previous { for await _ in previous {} }
        for await op in stream {
            if Task.isCancelled || !isCurrent(token) { break }
            await handle(op)
        }
    }
}
