import DeviceCore
import Foundation
import Observation
import os

/// 日志窗口的目标：跟随某个包的进程，或显示全部日志。
enum LogTarget: Hashable, Sendable {
    case package(String)
    case all

    var package: String? {
        if case .package(let p) = self { return p }
        return nil
    }
}

/// 日志窗口的一行：一条记录或一条分隔行。id 为会话内递增的序号。
enum LogLine: Equatable, Identifiable, Sendable {
    case entry(LogEntry, id: Int)
    case separator(String, id: Int)

    var id: Int {
        switch self {
        case .entry(_, let id), .separator(_, let id): id
        }
    }

    var entry: LogEntry? {
        if case .entry(let e, _) = self { return e }
        return nil
    }
}

/// 日志会话的连接状态。
enum LogStatus: Equatable, Sendable {
    case waitingForProcess, streaming, disconnected

    /// 状态行文案；正常接收时为 nil。
    var message: String? {
        switch self {
        case .waitingForProcess: "等待进程启动…"
        case .streaming: nil
        case .disconnected: "设备已断开"
        }
    }
}

/// 一台设备日志窗口的数据（spec §3.6）：补历史、跟随 pid、接收 logcat 流、环形缓冲、过滤、暂停与导出。
///
/// 流在后台任务里读取并累积到 `LogBatch`，每个批量间隔在主线程一次性提交到 `lines`，
/// 「全部」模式每秒上千行时界面也只按批量间隔刷新。
@MainActor @Observable
final class LogSession {
    static let historyLines = 2000

    let deviceID: String
    private(set) var target: LogTarget
    private(set) var status: LogStatus = .streaming
    /// 收集到的全部行，最多 `capacity` 条，超出丢弃最早的。
    private(set) var lines: [LogLine] = [] {
        didSet { linesRevision &+= 1 }
    }
    /// 过滤后的显示内容；分隔行总是保留。暂停时冻结。
    private(set) var visible: [LogLine] = []
    var minLevel: LogLevel = .verbose {
        didSet { if minLevel != oldValue { refilter() } }
    }
    /// 不区分大小写的子串，匹配 tag 或内容；空串不过滤。
    var keyword = "" {
        didSet { if keyword != oldValue { refilter() } }
    }
    var paused = false {
        didSet { if paused != oldValue { pausedChanged() } }
    }
    /// 暂停以来新增的条目数；超出容量的部分已被丢弃，故不超过 `capacity`。
    private(set) var pendingCount = 0

    /// `lines` 每变更一次加一（验证批量提交）。
    @ObservationIgnored private(set) var linesRevision = 0
    /// 后台已收到、尚未提交的条目数（含因后台批上限丢弃的）。
    var bufferedCount: Int { batch?.count ?? 0 }

    @ObservationIgnored private let actions: () async -> (any DeviceActions)?
    @ObservationIgnored private let capacity: Int
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let batchInterval: Duration
    @ObservationIgnored private let sleep: (Duration) async throws -> Void

    @ObservationIgnored private var nextID = 0
    /// 每次切换目标加一：过期的补历史、轮询与提交一律丢弃。
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var backfilledGeneration: Int?
    @ObservationIgnored private var backfillingGeneration: Int?
    /// 当前代的接收任务（连接、断开重试）；切换目标时取消。
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    /// 当前连接的后台批。
    @ObservationIgnored private var batch: LogBatch?
    /// 正在跟随的 pid 集合；nil 表示本代还没查过。
    @ObservationIgnored private var pids: Set<Int>?
    /// 最近一次非空的 pid 集合：进程退出后再启动时，分隔行从它写起。
    @ObservationIgnored private var lastPids: Set<Int>?
    /// 暂停时冻结的行，过滤改动只作用于它。
    @ObservationIgnored private var frozen: [LogLine]?
    /// run 等待别处的补历史完成时挂起在这里。
    @ObservationIgnored private var runWaiter: CheckedContinuation<Void, Never>?

    init(deviceID: String, actions: @escaping () async -> (any DeviceActions)?, target: LogTarget = .all,
         capacity: Int = 50_000, pollInterval: Duration = .seconds(2), batchInterval: Duration = .milliseconds(100),
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.deviceID = deviceID
        self.actions = actions
        self.target = target
        self.capacity = max(1, capacity)
        self.pollInterval = pollInterval
        self.batchInterval = batchInterval
        self.sleep = sleep
    }

    // MARK: 生命周期

    /// 补历史后持续接收，直到取消（关闭窗口）；取消时 logcat 进程随流终止。
    func run() async {
        while !Task.isCancelled {
            let gen = generation
            if backfilledGeneration != gen {
                if backfillingGeneration == gen { await waitForBackfill() } else { await backfill(gen) }
                continue
            }
            let task = Task { await self.receive(gen) }
            streamTask = task
            await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            if streamTask == task { streamTask = nil }
        }
    }

    /// 切换目标：停掉当前的流与轮询，清空，用快照补历史，再由 run 接上新目标的流。
    func setTarget(_ newTarget: LogTarget) async {
        target = newTarget
        generation += 1
        streamTask?.cancel()
        streamTask = nil
        batch = nil
        pids = nil
        lastPids = nil
        status = .streaming
        resetLines()
        await backfill(generation)
    }

    func clear() {
        batch?.discard()
        resetLines()
    }

    /// 当前过滤后的内容，每行 `time pid tid L tag: message`，分隔行原样。
    func exportText() -> String {
        visible.map { line in
            switch line {
            case .entry(let e, _): "\(e.time) \(e.pid) \(e.tid) \(e.level.rawValue) \(e.tag): \(e.message)\n"
            case .separator(let text, _): text + "\n"
            }
        }.joined()
    }

    // MARK: 补历史

    private func backfill(_ gen: Int) async {
        backfillingGeneration = gen
        defer {
            if backfillingGeneration == gen { backfillingGeneration = nil }
            runWaiter?.resume()
            runWaiter = nil
        }
        let query = LogQuery(package: target.package, minLevel: .verbose, grep: nil, lines: Self.historyLines)
        var history: [LogEntry] = []
        if let device = await actions() {
            history = (try? await device.logSnapshot(query))?.entries ?? []
        }
        guard gen == generation else { return }
        commit(history.map(makeEntry), counted: history.count)
        backfilledGeneration = gen
    }

    private func waitForBackfill() async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                if Task.isCancelled { c.resume() } else { runWaiter = c }
            }
        } onCancel: {
            Task { @MainActor in
                self.runWaiter?.resume()
                self.runWaiter = nil
            }
        }
    }

    // MARK: 接收

    /// 一代目标的接收循环：连接，流结束即视为设备断开，按轮询间隔重试。
    private func receive(_ gen: Int) async {
        while !Task.isCancelled, gen == generation {
            await connect(gen)
            guard !Task.isCancelled, gen == generation else { return }
            status = .disconnected
            do { try await sleep(pollInterval) } catch { return }
        }
    }

    /// 一次连接：后台读流，同时按批量间隔提交、按轮询间隔查 pid，直到流结束或被取消。
    private func connect(_ gen: Int) async {
        guard let device = await actions(), gen == generation, !Task.isCancelled else { return }
        let stream: AsyncThrowingStream<LogEntry, any Error>
        do { stream = try device.logStream() } catch { return }
        let package = target.package
        // 包目标在查到 pid 之前先暂存所有条目，查到后取回属于它的。
        let batch = LogBatch(capacity: capacity, filter: package == nil ? nil : (pids ?? []),
                             skipIfFirst: lines.last { $0.entry != nil }?.entry)
        self.batch = batch
        if package == nil { status = .streaming }

        let drain = Task.detached {
            do {
                for try await entry in stream { batch.add(entry) }
            } catch {}
        }
        let flusher = Task { await self.flushLoop(batch, gen) }
        let poller = package.map { pkg in Task { await self.pollLoop(pkg, device, batch, gen) } }
        await withTaskCancellationHandler { await drain.value } onCancel: { drain.cancel() }
        flusher.cancel()
        poller?.cancel()
        flush(batch, gen)
        if self.batch === batch { self.batch = nil }
    }

    private func flushLoop(_ batch: LogBatch, _ gen: Int) async {
        while true {
            do { try await sleep(batchInterval) } catch { return }
            guard !Task.isCancelled else { return }
            flush(batch, gen)
        }
    }

    private func flush(_ batch: LogBatch, _ gen: Int) {
        guard gen == generation, self.batch === batch else { return }
        let (entries, dropped) = batch.take()
        commit(entries.map(makeEntry), counted: entries.count + dropped)
    }

    private func pollLoop(_ package: String, _ device: any DeviceActions, _ batch: LogBatch, _ gen: Int) async {
        while !Task.isCancelled {
            let mark = batch.heldMark()
            if let found = try? await device.pids(of: package), gen == generation, !Task.isCancelled {
                applyPids(Set(found), batch, mark: mark)
            }
            do { try await sleep(pollInterval) } catch { return }
        }
    }

    /// pid 集合变化：先提交旧进程的条目，再插分隔行，再接上暂存中属于新进程的条目。
    private func applyPids(_ found: Set<Int>, _ batch: LogBatch, mark: Int) {
        guard self.batch === batch else { return }
        status = found.isEmpty ? .waitingForProcess : .streaming
        guard found != pids else {
            batch.dropHeld(upTo: mark)
            return
        }
        let (before, dropped, promoted) = batch.retarget(found, mark: mark)
        var new = before.map(makeEntry)
        if !found.isEmpty {
            if let old = lastPids, old != found {
                new.append(.separator("—— 进程重启（pid \(Self.describe(old)) → \(Self.describe(found))）——", id: takeID()))
            }
            lastPids = found
        }
        new += promoted.map(makeEntry)
        pids = found
        commit(new, counted: before.count + dropped + promoted.count)
    }

    /// pid 集合写作升序、逗号分隔，如 `10,12`。
    private static func describe(_ pids: Set<Int>) -> String {
        pids.sorted().map(String.init).joined(separator: ",")
    }

    // MARK: 缓冲与过滤

    private func takeID() -> Int {
        nextID += 1
        return nextID
    }

    private func makeEntry(_ e: LogEntry) -> LogLine { .entry(e, id: takeID()) }

    /// 追加到环形缓冲（`lines` 只变更一次）；未暂停时同步更新显示，暂停时只计数。
    private func commit(_ new: [LogLine], counted: Int) {
        guard !new.isEmpty else { return }
        Self.append(new, to: &lines, capacity: capacity)
        let firstID = lines.first?.id ?? 0
        if paused {
            pendingCount = min(pendingCount + counted, capacity)
            return
        }
        let stale = visible.prefix { $0.id < firstID }.count
        if stale > 0 { visible.removeFirst(stale) }
        visible += new.filter { $0.id >= firstID && matches($0) }
    }

    private static func append(_ new: [LogLine], to lines: inout [LogLine], capacity: Int) {
        if new.count >= capacity {
            lines = Array(new.suffix(capacity))
            return
        }
        let overflow = lines.count + new.count - capacity
        if overflow > 0 { lines.removeFirst(overflow) }
        lines += new
    }

    private func resetLines() {
        lines = []
        visible = []
        pendingCount = 0
        if paused { frozen = [] }
    }

    private func pausedChanged() {
        pendingCount = 0
        if paused {
            frozen = lines
        } else {
            frozen = nil
            refilter()
        }
    }

    private func refilter() {
        visible = (frozen ?? lines).filter(matches)
    }

    private func matches(_ line: LogLine) -> Bool {
        guard case .entry(let e, _) = line else { return true }
        guard e.level >= minLevel else { return false }
        guard !keyword.isEmpty else { return true }
        return e.tag.range(of: keyword, options: .caseInsensitive) != nil
            || e.message.range(of: keyword, options: .caseInsensitive) != nil
    }
}

/// 后台累积的一批流条目（加锁，读流的后台任务写入、主线程按批量间隔取走）。
///
/// 包目标下按 pid 集合过滤：不属于当前集合的条目暂存起来，下次轮询发现新 pid 时取回，
/// 新进程在两次轮询之间的启动日志因此不会丢。待提交与暂存各自最多保留约 `capacity` 条最新的，
/// 主线程停顿时内存仍有上限。
final class LogBatch: Sendable {
    private struct State {
        /// nil 为不过滤（「全部」）。
        var filter: Set<Int>?
        var pending: [LogEntry] = []
        /// 待提交中因上限丢弃的条数。
        var dropped = 0
        var held: [LogEntry] = []
        /// 已从暂存前端移走的条数，用来把暂存位置换算成全局序号。
        var heldRemoved = 0
        /// 流的第一条若与它相同则跳过：`logcat -T 1` 从缓冲里最新的一行开始，常与已有的最后一行重复。
        var skipIfFirst: LogEntry?
        var received = false
    }

    private let capacity: Int
    /// 超过 capacity 这么多再一次性裁剪，摊销数组前端删除的开销。
    private let slack: Int
    private let state: OSAllocatedUnfairLock<State>

    init(capacity: Int, filter: Set<Int>?, skipIfFirst: LogEntry?) {
        self.capacity = capacity
        self.slack = max(1, capacity / 4)
        state = OSAllocatedUnfairLock(initialState: State(filter: filter, skipIfFirst: skipIfFirst))
    }

    /// 已收到、尚未取走的条目数（含因上限丢弃的）。
    var count: Int { state.withLock { $0.pending.count + $0.dropped } }

    func add(_ entry: LogEntry) {
        let capacity = capacity, slack = slack
        state.withLock { s in
            defer { s.received = true }
            if !s.received, entry == s.skipIfFirst { return }
            if let filter = s.filter, !filter.contains(entry.pid) {
                s.held.append(entry)
                if s.held.count > capacity + slack {
                    let n = s.held.count - capacity
                    s.held.removeFirst(n)
                    s.heldRemoved += n
                }
                return
            }
            s.pending.append(entry)
            if s.pending.count > capacity + slack {
                let n = s.pending.count - capacity
                s.pending.removeFirst(n)
                s.dropped += n
            }
        }
    }

    /// 取走待提交的条目（最多 capacity 条最新的）与此前丢弃的条数。
    func take() -> (entries: [LogEntry], dropped: Int) {
        let capacity = capacity
        return state.withLock { s in
            let all = s.pending
            let extra = max(0, all.count - capacity)
            let result = (Array(all.suffix(capacity)), s.dropped + extra)
            s.pending = []
            s.dropped = 0
            return result
        }
    }

    /// 暂存的当前位置：轮询开始前记下，轮询结果回来后据此只清掉更早的暂存。
    func heldMark() -> Int { state.withLock { $0.heldRemoved + $0.held.count } }

    /// pid 集合没变：清掉 mark 之前暂存的条目（它们不属于任何跟随中的进程）。
    func dropHeld(upTo mark: Int) {
        state.withLock { s in
            let n = min(s.held.count, max(0, mark - s.heldRemoved))
            s.held.removeFirst(n)
            s.heldRemoved += n
        }
    }

    /// 换成新的 pid 集合：返回换之前待提交的条目、丢弃数，以及暂存中属于新集合的条目；
    /// mark 之前其余的暂存清掉，之后的留待下次轮询。
    func retarget(_ pids: Set<Int>, mark: Int) -> (before: [LogEntry], dropped: Int, promoted: [LogEntry]) {
        let capacity = capacity
        return state.withLock { s in
            let before = Array(s.pending.suffix(capacity))
            let dropped = s.dropped + max(0, s.pending.count - capacity)
            var promoted: [LogEntry] = []
            var kept: [LogEntry] = []
            for (i, e) in s.held.enumerated() {
                if pids.contains(e.pid) {
                    promoted.append(e)
                } else if s.heldRemoved + i >= mark {
                    kept.append(e)
                }
            }
            s.heldRemoved += s.held.count - kept.count
            s.held = kept
            s.pending = []
            s.dropped = 0
            s.filter = pids
            return (before, dropped, promoted)
        }
    }

    /// 清空：丢掉待提交与暂存的条目。
    func discard() {
        state.withLock { s in
            s.heldRemoved += s.held.count
            s.held = []
            s.pending = []
            s.dropped = 0
        }
    }
}
