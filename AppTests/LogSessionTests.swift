import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct LogSessionTests {
    private let batch = Duration.milliseconds(100)
    private let poll = Duration.seconds(2)

    private struct Env {
        let session: LogSession
        let actions: RecordingActions
        let streams: LogStreamSource
        let clock: ManualClock
    }

    private func make(_ target: LogTarget = .all, capacity: Int = 50_000, pids: [[Int]] = [],
                      history: [LogEntry] = []) -> Env {
        let actions = RecordingActions()
        let streams = LogStreamSource()
        actions.logStreams = streams
        actions.pidsResults = pids
        actions.logSnapshotResult = LogSnapshot(entries: history, pids: [])
        let clock = ManualClock()
        let session = LogSession(
            deviceID: "d1", actions: { actions }, target: target, capacity: capacity,
            pollInterval: poll, batchInterval: batch, sleep: { try await clock.sleep($0) })
        return Env(session: session, actions: actions, streams: streams, clock: clock)
    }

    private func entry(_ n: Int, pid: Int = 10, level: LogLevel = .info, tag: String = "T",
                       _ message: String? = nil) -> LogEntry {
        LogEntry(time: String(format: "10-18 10:00:%02d.000", n % 60), pid: pid, tid: pid + 1, level: level,
                 tag: tag, message: message ?? "m\(n)")
    }

    /// 启动 run，等到流已打开且 flush 循环已在等待批量间隔。
    private func start(_ e: Env, streams: Int = 1) async -> Task<Void, Never> {
        let session = e.session
        let task = Task { await session.run() }
        await until { e.streams.opened == streams }
        await e.clock.waitForSleeper(batch)
        return task
    }

    /// 推送条目并等到它们进入后台批。
    private func push(_ e: Env, _ entries: [LogEntry], buffered: Int? = nil) async {
        let expected = e.session.bufferedCount + (buffered ?? entries.count)
        e.streams.yield(entries)
        await until { e.session.bufferedCount == expected }
    }

    /// 推进一个批量间隔，让后台批提交到 lines。
    private func flush(_ e: Env) async {
        let before = e.session.linesRevision
        await e.clock.tick(batch)
        await until { e.session.linesRevision != before || e.session.bufferedCount == 0 }
    }

    private func stop(_ task: Task<Void, Never>) async {
        task.cancel()
        await task.value
    }

    private func entries(_ lines: [LogLine]) -> [LogEntry] { lines.compactMap(\.entry) }

    /// 轮询等待条件成立（最多约 2 秒）。
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<1000 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
    }

    @Test func ringBufferDropsOldest() async {
        let e = make(capacity: 5)
        let run = await start(e)
        let all = (1...8).map { entry($0) }
        await push(e, Array(all[0..<4]))
        await flush(e)
        await push(e, Array(all[4..<8]))
        await flush(e)
        #expect(entries(e.session.lines) == Array(all[3..<8]))
        #expect(entries(e.session.visible) == Array(all[3..<8]))
        await stop(run)
    }

    @Test func oversizedBatchKeepsNewest() async {
        let e = make(capacity: 5)
        let run = await start(e)
        let all = (1...8).map { entry($0) }
        // 后台批也有上限：主线程停顿时只保留最新的条目。
        await push(e, all)
        await flush(e)
        #expect(entries(e.session.lines) == Array(all[3..<8]))
        await stop(run)
    }

    @Test func batchesAreCoalesced() async {
        let e = make()
        let run = await start(e)
        let all = (0..<1000).map { entry($0) }
        await push(e, all)
        #expect(e.session.lines.isEmpty)
        let before = e.session.linesRevision
        await flush(e)
        #expect(e.session.linesRevision - before == 1)
        #expect(entries(e.session.lines) == all)
        await stop(run)
    }

    @Test func filtersByPidSet() async {
        let e = make(.package("com.demo"), pids: [[10]])
        let run = await start(e)
        await until { e.session.status == .streaming && e.actions.calls.contains("pids com.demo") }
        await push(e, [entry(1, pid: 10), entry(2, pid: 20), entry(3, pid: 10)], buffered: 2)
        await flush(e)
        #expect(entries(e.session.lines).map(\.pid) == [10, 10])
        await stop(run)
    }

    @Test func pidChangeInsertsSeparator() async {
        let e = make(.package("com.demo"), pids: [[10], [11]])
        let run = await start(e)
        await until { e.session.status == .streaming }
        // 新进程在下次轮询前就开始输出：这些条目先暂存，发现新 pid 后接在分隔行之后。
        await push(e, [entry(1, pid: 10), entry(2, pid: 11)], buffered: 1)
        await flush(e)
        await e.clock.tick(poll)
        await until { e.session.lines.count == 3 }
        #expect(e.session.lines.map(\.text) == [
            "m1", "—— 进程重启（pid 10 → 11）——", "m2",
        ])
        await push(e, [entry(3, pid: 10), entry(4, pid: 11)], buffered: 1)
        await flush(e)
        #expect(entries(e.session.lines).map(\.message) == ["m1", "m2", "m4"])
        await stop(run)
    }

    @Test func notRunningWaits() async {
        let e = make(.package("com.demo"), pids: [[]])
        let run = await start(e)
        await until { e.session.status == .waitingForProcess }
        #expect(e.session.status == .waitingForProcess)
        #expect(e.session.status.message == "等待进程启动…")
        e.streams.yield([entry(1, pid: 10)])
        await e.clock.tick(batch)
        await e.clock.waitForSleeper(batch)
        #expect(e.session.lines.isEmpty)
        await stop(run)
    }

    @Test func exitThenStartSeparatesFromLastPid() async {
        let e = make(.package("com.demo"), pids: [[10], [], [11]])
        let run = await start(e)
        await until { e.session.status == .streaming }
        await push(e, [entry(1, pid: 10)])
        await flush(e)
        await e.clock.tick(poll)
        await until { e.session.status == .waitingForProcess }
        #expect(e.session.lines.count == 1)
        await e.clock.tick(poll)
        await until { e.session.status == .streaming }
        #expect(e.session.lines.map(\.text) == ["m1", "—— 进程重启（pid 10 → 11）——"])
        await stop(run)
    }

    @Test func separatorListsSeveralPids() async {
        let e = make(.package("com.demo"), pids: [[12, 10], [11, 13]])
        let run = await start(e)
        await until { e.session.status == .streaming }
        await e.clock.waitForSleeper(poll)
        await e.clock.tick(poll)
        await until { !e.session.lines.isEmpty }
        #expect(e.session.lines.map(\.text) == ["—— 进程重启（pid 10,12 → 11,13）——"])
        await stop(run)
    }

    @Test func historyComesFirst() async {
        let history = [entry(1), entry(2), entry(3)]
        let e = make(.package("com.demo"), pids: [[10]], history: history)
        let run = await start(e)
        await until { e.session.status == .streaming }
        await push(e, [entry(4), entry(5)])
        await flush(e)
        #expect(entries(e.session.lines).map(\.message) == ["m1", "m2", "m3", "m4", "m5"])
        #expect(e.actions.logQueries == [LogQuery(package: "com.demo", minLevel: .verbose, grep: nil, lines: 2000)])
        await stop(run)
    }

    @Test func firstStreamLineRepeatingHistoryIsSkipped() async {
        // logcat -T 1 从缓冲里最新的一行开始，它往往正是快照的最后一行。
        let e = make(history: [entry(1), entry(2)])
        let run = await start(e)
        await push(e, [entry(2), entry(3)], buffered: 1)
        await flush(e)
        #expect(entries(e.session.lines).map(\.message) == ["m1", "m2", "m3"])
        await stop(run)
    }

    @Test func allTargetStreamsWithoutPolling() async {
        let e = make()
        let run = await start(e)
        await until { e.session.status == .streaming }
        #expect(e.session.status == .streaming)
        #expect(!e.actions.calls.contains { $0.hasPrefix("pids") })
        #expect(e.actions.logQueries.map(\.package) == [nil])
        await stop(run)
    }

    @Test func disconnectRetriesAndKeepsLines() async {
        let e = make()
        let run = await start(e)
        await push(e, [entry(1)])
        await flush(e)
        e.streams.finish()
        await until { e.session.status == .disconnected }
        #expect(e.session.status.message == "设备已断开")
        await e.clock.tick(poll)
        await until { e.streams.opened == 2 && e.session.status == .streaming }
        await e.clock.waitForSleeper(batch)
        await push(e, [entry(2)])
        await flush(e)
        #expect(entries(e.session.lines).map(\.message) == ["m1", "m2"])
        #expect(e.actions.logQueries.count == 1)
        await stop(run)
        await until { e.streams.cancelled == 1 }
        #expect(e.streams.cancelled == 1)
    }

    @Test func noActionsMeansDisconnected() async {
        let clock = ManualClock()
        let session = LogSession(deviceID: "d1", actions: { nil }, sleep: { try await clock.sleep($0) })
        let run = Task { await session.run() }
        await until { session.status == .disconnected }
        #expect(session.status == .disconnected)
        await stop(run)
    }

    @Test func pauseFreezesVisible() async {
        let e = make()
        let run = await start(e)
        await push(e, [entry(1), entry(2)])
        await flush(e)
        e.session.paused = true
        await push(e, [entry(3), entry(4), entry(5)])
        await flush(e)
        #expect(e.session.lines.count == 5)
        #expect(entries(e.session.visible).map(\.message) == ["m1", "m2"])
        #expect(e.session.pendingCount == 3)
        // 暂停时改过滤只作用于冻结的内容。
        e.session.keyword = "m2"
        #expect(entries(e.session.visible).map(\.message) == ["m2"])
        e.session.keyword = ""
        e.session.paused = false
        #expect(entries(e.session.visible).map(\.message) == ["m1", "m2", "m3", "m4", "m5"])
        #expect(e.session.pendingCount == 0)
        await stop(run)
    }

    @Test func pausedCountIsCappedAtCapacity() async {
        let e = make(capacity: 5)
        let run = await start(e)
        e.session.paused = true
        for chunk in [(1...4), (5...8)] {
            await push(e, chunk.map { entry($0) })
            await flush(e)
        }
        #expect(e.session.pendingCount == 5)
        #expect(e.session.visible.isEmpty)
        e.session.paused = false
        #expect(entries(e.session.visible).map(\.message) == ["m4", "m5", "m6", "m7", "m8"])
        await stop(run)
    }

    @Test func levelAndKeywordFilter() async {
        let history = [
            entry(1, level: .debug, tag: "Net", "connect"),
            entry(2, level: .warn, tag: "Net", "slow"),
            entry(3, level: .error, tag: "UI", "NETWORK down"),
            entry(4, level: .error, tag: "UI", "crash"),
        ]
        let e = make(.package("com.demo"), pids: [[10], [11]], history: history)
        let run = await start(e)
        await until { e.session.status == .streaming }
        await e.clock.waitForSleeper(poll)
        await e.clock.tick(poll)
        await until { e.session.lines.count == 5 }
        e.session.minLevel = .warn
        #expect(e.session.visible.map(\.text) == ["slow", "NETWORK down", "crash", "—— 进程重启（pid 10 → 11）——"])
        e.session.keyword = "net"
        #expect(e.session.visible.map(\.text) == ["slow", "NETWORK down", "—— 进程重启（pid 10 → 11）——"])
        #expect(e.session.lines.count == 5)
        await stop(run)
    }

    @Test func exportFormat() async {
        let history = [entry(1, level: .warn, tag: "Net", "slow"), entry(2, level: .debug, tag: "UI", "tap")]
        let e = make(.package("com.demo"), pids: [[10], [11]], history: history)
        let run = await start(e)
        await until { e.session.status == .streaming }
        await e.clock.waitForSleeper(poll)
        await e.clock.tick(poll)
        await until { e.session.lines.count == 3 }
        e.session.minLevel = .info
        #expect(e.session.exportText() == """
            10-18 10:00:01.000 10 11 W Net: slow
            —— 进程重启（pid 10 → 11）——

            """)
        await stop(run)
    }

    @Test func clearEmptiesLines() async {
        let e = make()
        let run = await start(e)
        await push(e, [entry(1)])
        await flush(e)
        await push(e, [entry(2)])
        e.session.clear()
        #expect(e.session.lines.isEmpty)
        #expect(e.session.visible.isEmpty)
        await e.clock.tick(batch)
        await e.clock.waitForSleeper(batch)
        #expect(e.session.lines.isEmpty)
        await push(e, [entry(3)])
        await flush(e)
        #expect(entries(e.session.lines).map(\.message) == ["m3"])
        await stop(run)
    }

    @Test func setTargetRestartsWithNewHistory() async {
        let e = make()
        e.actions.logSnapshotResults = ["com.b": LogSnapshot(entries: [entry(9, pid: 20)], pids: [20])]
        e.actions.pidsResults = [[20]]
        let run = await start(e)
        await push(e, [entry(1)])
        await flush(e)
        await e.session.setTarget(.package("com.b"))
        #expect(e.session.target == .package("com.b"))
        #expect(entries(e.session.lines).map(\.message) == ["m9"])
        await until { e.streams.opened == 2 && e.streams.cancelled == 1 && e.session.status == .streaming }
        #expect(e.streams.cancelled == 1)
        await e.clock.waitForSleeper(batch)
        await push(e, [entry(10, pid: 20)])
        await flush(e)
        #expect(entries(e.session.lines).map(\.message) == ["m9", "m10"])
        await stop(run)
    }

    @Test func staleBackfillIsDiscarded() async {
        let e = make()
        let gate = TransferGate()
        e.actions.logSnapshotResults = [
            "com.a": LogSnapshot(entries: [entry(1, pid: 20)], pids: [20]),
            "com.b": LogSnapshot(entries: [entry(2, pid: 30)], pids: [30]),
        ]
        e.actions.logSnapshotHook = { q in if q.package == "com.a" { try? await gate.wait() } }
        let session = e.session
        let first = Task { await session.setTarget(.package("com.a")) }
        await until { e.actions.logQueries.count == 1 }
        await session.setTarget(.package("com.b"))
        gate.release()
        await first.value
        #expect(session.target == .package("com.b"))
        #expect(entries(session.lines).map(\.message) == ["m2"])
    }
}

/// 手动推进的时钟：sleep 挂起到 tick 越过其截止时间；任务取消时抛 CancellationError。
final class ManualClock: @unchecked Sendable {
    private struct Sleeper {
        let id: Int
        let duration: Duration
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var now = Duration.zero
    private var nextID = 0
    private var sleepers: [Sleeper] = []
    private var cancelledIDs: Set<Int> = []

    func sleep(_ duration: Duration) async throws {
        let id = lock.withLock { nextID += 1; return nextID }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let cancelled = lock.withLock {
                    if cancelledIDs.remove(id) != nil { return true }
                    sleepers.append(Sleeper(id: id, duration: duration, deadline: now + duration, continuation: c))
                    return false
                }
                if cancelled { c.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let c = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                guard let i = sleepers.firstIndex(where: { $0.id == id }) else {
                    cancelledIDs.insert(id)
                    return nil
                }
                return sleepers.remove(at: i).continuation
            }
            c?.resume(throwing: CancellationError())
        }
    }

    /// 等到有任务以该时长在睡眠（最多约 2 秒）。
    func waitForSleeper(_ duration: Duration) async {
        for _ in 0..<1000 {
            if lock.withLock({ sleepers.contains { $0.duration == duration } }) { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// 等到有任务以该时长在睡眠，再把时间推进该时长，唤醒所有到期的睡眠。
    func tick(_ duration: Duration) async {
        await waitForSleeper(duration)
        let due = lock.withLock { () -> [Sleeper] in
            now += duration
            let due = sleepers.filter { $0.deadline <= now }
            sleepers.removeAll { $0.deadline <= now }
            return due
        }
        for s in due { s.continuation.resume() }
    }
}

private extension LogLine {
    /// 测试用：条目取消息，分隔行取原文。
    var text: String {
        switch self {
        case .entry(let e, _): e.message
        case .separator(let s, _): s
        }
    }
}
