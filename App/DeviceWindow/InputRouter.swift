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
    private var previousDone: Task<Void, Never>?
    /// 合批模式下，stream 只负责唤醒；相邻文字、同来源移动和同位置滚轮在入队时合并。
    private var pending: [Op]?

    func open() -> (token: Token, stream: AsyncStream<Op>) {
        open(coalescing: false)
    }

    private func open(coalescing: Bool) -> (token: Token, stream: AsyncStream<Op>) {
        let (stream, c) = AsyncStream<Op>.makeStream(bufferingPolicy: coalescing ? .bufferingNewest(1) : .unbounded)
        lock.lock()
        generation += 1
        let token = generation
        continuation?.finish()
        continuation = c
        pending = coalescing ? [] : nil
        lock.unlock()
        return (token, stream)
    }

    /// 仅当 token 仍是当前一轮时才结束 stream。
    func close(_ token: Token) {
        lock.lock(); defer { lock.unlock() }
        guard token == generation else { return }
        continuation?.finish()
        continuation = nil
        pending = nil
    }

    func isCurrent(_ token: Token) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return token == generation
    }

    func yield(_ op: Op) {
        lock.lock(); defer { lock.unlock() }
        guard pending != nil else { continuation?.yield(op); return }
        let needsWakeup = pending!.isEmpty
        switch (pending!.last, op) {
        case let (.action(.text(previous))?, .action(.text(next))):
            pending![pending!.count - 1] = .action(.text(previous + next))
        case let (.action(.touch(.move, _, previous))?, .action(.touch(.move, _, next))) where previous == next:
            pending![pending!.count - 1] = op
        case let (.action(.scroll(previousPoint, previousX, previousY))?, .action(.scroll(point, dx, dy)))
            where previousPoint == point && (previousX + dx).isFinite && (previousY + dy).isFinite:
            pending![pending!.count - 1] = .action(.scroll(point, dx: previousX + dx, dy: previousY + dy))
        default:
            pending!.append(op)
        }
        if needsWakeup { continuation?.yield(op) }
    }

    /// 操作在入队时已合并；替换 run 会直接丢弃旧队列。
    private func dequeue(_ token: Token) -> Op? {
        lock.lock(); defer { lock.unlock() }
        guard token == generation, pending?.isEmpty == false else { return nil }
        return pending!.removeFirst()
    }

    private func swapPreviousDone(_ done: Task<Void, Never>) -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        let previous = previousDone
        previousDone = done
        return previous
    }

    func run(coalescing: Bool = false, _ handle: @escaping @Sendable (Op) async -> Void) async {
        let (token, stream) = open(coalescing: coalescing)
        let (done, doneC) = AsyncStream<Void>.makeStream()
        // 取消正在等待的 run 也必须等前一轮真正结束，不能让下一轮越过仍在发送的操作。
        let completion = Task.detached { for await _ in done {} }
        let previous = swapPreviousDone(completion)
        defer { close(token); doneC.finish() }
        if let previous { await previous.value }
        var touches: [(pointer: TouchPointer, point: NormalizedPoint)] = []
        func delivered(_ op: Op) {
            guard coalescing, case let .action(.touch(phase, point, pointer)) = op else { return }
            let index = touches.firstIndex { $0.pointer == pointer }
            switch phase {
            case .down:
                if let index { touches[index].point = point }
                else { touches.append((pointer, point)) }
            case .move:
                if let index { touches[index].point = point }
            case .up:
                if let index { touches.remove(at: index) }
            }
        }
        for await op in stream {
            if Task.isCancelled || !isCurrent(token) { break }
            if coalescing {
                while !Task.isCancelled, isCurrent(token), let next = dequeue(token) {
                    await handle(next)
                    delivered(next)
                }
            } else {
                await handle(op)
            }
        }
        // 消费者被取消或替换时，待发送的 up 会随队列丢弃。
        // 独立任务只释放本轮已交付的触点，完成后才放行下一轮消费者。
        let releases = touches.map { Op.action(.touch(.up, $0.point, pointer: $0.pointer)) }
        if !releases.isEmpty {
            await Task.detached {
                for release in releases { await handle(release) }
            }.value
        }
    }
}
