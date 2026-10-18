import Testing
import Foundation
import DeviceCore
@testable import MagicDevX

/// 不受取消影响的闸门（模拟 session.send 不响应取消）。
private actor Gate {
    private var open = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release() { open = true; waiter?.resume(); waiter = nil }
}

private actor Log {
    var items: [String] = []
    func add(_ s: String) { items.append(s) }
}

@Test func staleCloseKeepsNewStreamWorking() async {
    let r = InputRouter()
    let (t1, _) = r.open()
    let (_, s2) = r.open()
    r.close(t1)
    r.yield(.action(.key(.home)))
    var it = s2.makeAsyncIterator()
    #expect(await it.next() == .action(.key(.home)))
}

@Test func supersededConsumerStopsAndNewOneKeepsOrder() async throws {
    let r = InputRouter()
    let log = Log()
    let gate = Gate()
    let (started, startedC) = AsyncStream<Void>.makeStream()

    let old = Task {
        await r.run { op in
            startedC.yield()
            await gate.wait()
            await log.add("old:\(op)")
        }
    }
    try await Task.sleep(for: .milliseconds(50))
    r.yield(.action(.key(.back)))       // 旧消费者正在处理（卡在 gate）
    var si = started.makeAsyncIterator()
    _ = await si.next()
    r.yield(.action(.key(.up)))         // 旧 stream 缓冲中，应被丢弃

    old.cancel()
    let new = Task {
        await r.run { op in await log.add("new:\(op)") }
    }
    try await Task.sleep(for: .milliseconds(50))
    r.yield(.action(.key(.home)))
    r.yield(.action(.key(.recents)))
    try await Task.sleep(for: .milliseconds(50))
    #expect(await log.items.isEmpty)    // 旧的还卡着，新的不得抢先发送
    await gate.release()
    try await Task.sleep(for: .milliseconds(200))
    #expect(await log.items == [
        "old:\(InputRouter.Op.action(.key(.back)))",
        "new:\(InputRouter.Op.action(.key(.home)))",
        "new:\(InputRouter.Op.action(.key(.recents)))",
    ])
    new.cancel()
    r.close(Int.max)
}
