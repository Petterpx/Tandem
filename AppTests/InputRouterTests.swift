import Testing
import Foundation
import DeviceCore
@testable import Tandem

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

private actor OpLog {
    var items: [InputRouter.Op] = []
    func add(_ op: InputRouter.Op) { items.append(op) }
}

@Suite struct InputRouterCoalescingTests {
    private func waitForCount(_ count: Int, in log: OpLog) async throws {
        for _ in 0..<100 {
            if await log.items.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("输入发送未在等待时间内完成")
    }

    @Test func wheelBurstWhileSendIsBusyDoesNotReplayEveryOldScroll() async throws {
        let router = InputRouter(), gate = Gate(), log = OpLog()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            await router.run(coalescing: true) { op in
                signal.yield()
                await gate.wait()
                await log.add(op)
            }
        }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(30))
        let first = InputRouter.Op.action(.scroll(.init(x: 0.5, y: 0.5), dx: 0, dy: -1))
        router.yield(first)
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        for _ in 0..<1000 { router.yield(first) }
        let end = InputRouter.Op.action(.key(.home))
        router.yield(end)
        await gate.release()
        try await waitForCount(3, in: log)
        #expect(await log.items == [
            first,
            .action(.scroll(.init(x: 0.5, y: 0.5), dx: 0, dy: -1000)),
            end,
        ])
    }

    @Test func cancellingConsumerReleasesItsDeliveredTouch() async throws {
        let router = InputRouter(), log = OpLog()
        let task = Task { await router.run(coalescing: true) { await log.add($0) } }
        try await Task.sleep(for: .milliseconds(30))
        router.yield(.action(.touch(.down, .init(x: 0.2, y: 0.3))))
        try await waitForCount(1, in: log)
        router.yield(.action(.touch(.move, .init(x: 0.4, y: 0.5))))
        try await waitForCount(2, in: log)
        task.cancel()
        await task.value
        #expect(await log.items == [
            .action(.touch(.down, .init(x: 0.2, y: 0.3))),
            .action(.touch(.move, .init(x: 0.4, y: 0.5))),
            .action(.touch(.up, .init(x: 0.4, y: 0.5))),
        ])
    }

    @Test func draggingWhileSendIsBusyKeepsLatestMoveAndRelease() async throws {
        let router = InputRouter(), gate = Gate(), log = OpLog()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            await router.run(coalescing: true) { op in
                signal.yield()
                await gate.wait()
                await log.add(op)
            }
        }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(30))
        let down = InputRouter.Op.action(.touch(.down, .init(x: 0, y: 0.5)))
        router.yield(down)
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        for index in 1...1000 {
            router.yield(.action(.touch(.move, .init(x: Double(index) / 1000, y: 0.5))))
        }
        let up = InputRouter.Op.action(.touch(.up, .init(x: 1, y: 0.5)))
        router.yield(up)
        await gate.release()
        try await waitForCount(3, in: log)
        #expect(await log.items == [down, .action(.touch(.move, .init(x: 1, y: 0.5))), up])
    }

    @Test func moveCoalescingPreservesSourceAndInputBoundaries() async throws {
        let router = InputRouter(), gate = Gate(), log = OpLog()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            await router.run(coalescing: true) { op in
                signal.yield()
                await gate.wait()
                await log.add(op)
            }
        }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(30))
        router.yield(.action(.key(.home)))
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        let operations: [InputRouter.Op] = [
            .action(.touch(.move, .init(x: 0.1, y: 0.2))),
            .action(.touch(.move, .init(x: 0.2, y: 0.2), pointer: .ai)),
            .action(.touch(.move, .init(x: 0.3, y: 0.2))),
            .action(.text("A")),
            .action(.touch(.move, .init(x: 0.4, y: 0.2))),
            .action(.touch(.up, .init(x: 0.4, y: 0.2))),
            .action(.touch(.down, .init(x: 0.5, y: 0.2))),
            .action(.touch(.move, .init(x: 0.6, y: 0.2))),
        ]
        for op in operations { router.yield(op) }
        await gate.release()
        try await waitForCount(9, in: log)
        #expect(await log.items == [.action(.key(.home))] + operations)
    }

    @Test func textQueuedWhileSendingIsCombined() async throws {
        let router = InputRouter(), gate = Gate(), log = OpLog()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            await router.run(coalescing: true) { op in
                signal.yield()
                await gate.wait()
                await log.add(op)
            }
        }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(30))
        router.yield(.action(.text("first")))
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        for letter in ["h", "e", "l", "l", "o"] { router.yield(.action(.text(letter))) }
        await gate.release()
        try await waitForCount(2, in: log)
        #expect(await log.items == [.action(.text("first")), .action(.text("hello"))])
    }

    @Test func keysTouchesAndExplicitPasteRemainOrderedBoundaries() async throws {
        let router = InputRouter(), gate = Gate(), log = OpLog()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            await router.run(coalescing: true) { op in
                signal.yield()
                await gate.wait()
                await log.add(op)
            }
        }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(30))
        router.yield(.action(.text("first")))
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        let touch = InputRouter.Op.action(.touch(.down, .init(x: 0.2, y: 0.3)))
        for op: InputRouter.Op in [
            .action(.text("h")), .action(.text("e")), .action(.key(.enter)),
            .action(.text("l")), .action(.text("l")), .paste("clipboard"),
            .action(.text("o")), touch, .action(.text("!")),
        ] { router.yield(op) }
        await gate.release()
        try await waitForCount(8, in: log)
        #expect(await log.items == [
            .action(.text("first")), .action(.text("he")), .action(.key(.enter)),
            .action(.text("ll")), .paste("clipboard"), .action(.text("o")), touch, .action(.text("!")),
        ])
    }

    @Test func replacementDropsOldTextAndWaitsForActiveSend() async throws {
        let router = InputRouter(), gate = Gate(), oldLog = OpLog(), newLog = OpLog()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let old = Task {
            await router.run(coalescing: true) { op in
                signal.yield()
                await gate.wait()
                await oldLog.add(op)
            }
        }
        defer { old.cancel() }
        try await Task.sleep(for: .milliseconds(30))
        router.yield(.action(.text("active")))
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        router.yield(.action(.text("discard")))
        old.cancel()
        let new = Task { await router.run(coalescing: true) { await newLog.add($0) } }
        defer { new.cancel() }
        try await Task.sleep(for: .milliseconds(30))
        router.yield(.action(.text("n")))
        router.yield(.action(.text("ew")))
        #expect(await newLog.items.isEmpty)
        await gate.release()
        try await waitForCount(1, in: newLog)
        #expect(await oldLog.items == [.action(.text("active"))])
        #expect(await newLog.items == [.action(.text("new"))])
    }

    @Test func defaultModePreservesEveryTextOperation() async throws {
        let router = InputRouter(), gate = Gate(), log = OpLog()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let task = Task {
            await router.run { op in
                signal.yield()
                await gate.wait()
                await log.add(op)
            }
        }
        defer { task.cancel() }
        try await Task.sleep(for: .milliseconds(30))
        router.yield(.action(.text("first")))
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        router.yield(.action(.text("a")))
        router.yield(.action(.text("b")))
        await gate.release()
        try await waitForCount(3, in: log)
        #expect(await log.items == [.action(.text("first")), .action(.text("a")), .action(.text("b"))])
    }

    @Test func cancelledWaitingRunCannotLetReplacementOvertakeActiveSend() async throws {
        let router = InputRouter(), gate = Gate(), log = OpLog()
        let (started, signal) = AsyncStream<Void>.makeStream()
        let old = Task {
            await router.run(coalescing: true) { op in
                signal.yield()
                await gate.wait()
                await log.add(op)
            }
        }
        defer { old.cancel() }
        try await Task.sleep(for: .milliseconds(30))
        router.yield(.action(.text("active")))
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        let middle = Task { await router.run(coalescing: true) { await log.add($0) } }
        defer { middle.cancel() }
        try await Task.sleep(for: .milliseconds(30))
        middle.cancel()
        let newest = Task { await router.run(coalescing: true) { await log.add($0) } }
        defer { newest.cancel() }
        try await Task.sleep(for: .milliseconds(30))
        router.yield(.action(.key(.home)))
        try await Task.sleep(for: .milliseconds(30))
        #expect(await log.items.isEmpty)
        await gate.release()
        try await waitForCount(2, in: log)
        #expect(await log.items == [.action(.text("active")), .action(.key(.home))])
    }
}
