import DeviceCore
import Foundation
import os

/// 一台 Android 设备的 scrcpy 会话：启动服务端、读视频流、发控制消息、处理断开。
///
/// 每次 `start()` 是一个 run（新的 scid、新的服务端进程）；run 结束时恰好调用一次 `launched.stop()`，
/// 并恰好发出一次终态（`.disconnected` / `.failed` / `.idle`）。
///
/// start/stop 按调用顺序串行执行；stop 在调用时立即取消进行中的 launch，并使排在它之前、尚未开始的 start 作废。
/// 控制消息经每个 run 唯一的写协程按入队顺序写出。
public actor AndroidSession: DeviceSession {
    public nonisolated let events: AsyncStream<SessionEvent>
    private nonisolated let continuation: AsyncStream<SessionEvent>.Continuation
    private nonisolated let frames = OSAllocatedUnfairLock(initialState: FrameState())
    private nonisolated let transport: OSAllocatedUnfairLock<Transport>

    private struct Transport: Sendable {
        /// 最新的设备信息；每次 start 读取其中的 serial 与传输方式。
        var device: DeviceInfo
        /// 进行中的 run 所用的 serial（state 为 connecting / running 时非 nil）。
        var active: String?
    }

    private struct FrameState: Sendable {
        var latest: VideoFrame?
        /// 当前 run；上一个 run 的解码器迟到的帧不再写入 latest。
        var runID = 0
        var observers: [Int: @Sendable (VideoFrame) -> Void] = [:]
        var nextObserverID = 0
    }

    private struct Outgoing: Sendable {
        let data: Data
        /// 写完（nil）或失败后调用。
        let done: @Sendable ((any Error)?) async -> Void
    }

    private struct Run {
        let id: Int
        let launched: LaunchedServer
        let writer: AsyncStream<Outgoing>.Continuation
        let writerTask: Task<Void, Never>
        /// 读循环（视频、控制、日志）；结束时取消。写协程不取消，而是 finish 后让它把队列写完。
        var tasks: [Task<Void, Never>] = []
        var videoSize: (width: Int, height: Int)?
        var injectPermissionReported = false
    }

    private struct Waiter<T: Sendable> {
        let continuation: CheckedContinuation<T, any Error>
        let timeout: Task<Void, Never>

        func fail(_ error: any Error) {
            timeout.cancel()
            continuation.resume(throwing: error)
        }
    }

    private static let logger = Logger(subsystem: "dev.tandem", category: "AndroidSession")
    private static let maxClipboardLength = 1 << 18

    private let launcher: any ScrcpyLauncher
    private let makeDecoder: @Sendable (@escaping @Sendable (VideoFrame) -> Void) -> any VideoDecoding
    private let clipboardTimeout: Duration

    private var state: SessionState = .idle
    /// start/stop 的串行链尾。
    private var lifecycle: Task<Void, Never>?
    /// 每次调用 stop() 时同步自增；start 据此判断自己是否已被之后的 stop 取代。
    private var stopRequests = 0
    private var nextRunID = 0
    private var run: Run?
    /// 进行中的 launch；stop 时立即取消，避免握手卡住时 start 永远不返回。
    private var launching: Task<LaunchedServer, any Error>?
    /// 进行中的 run 清理（等待 launched.stop() 并发出终态）。
    private var teardown: Task<Void, Never>?
    private var clipboardWaiters: [Int: Waiter<String>] = [:]
    private var ackWaiters: [UInt64: Waiter<Void>] = [:]
    private var nextWaiterID = 0
    private var nextSequence: UInt64 = 1

    public init(device: DeviceInfo, launcher: any ScrcpyLauncher,
                makeDecoder: @escaping @Sendable (@escaping @Sendable (VideoFrame) -> Void) -> any VideoDecoding) {
        self.init(device: device, launcher: launcher, makeDecoder: makeDecoder, clipboardTimeout: .seconds(2))
    }

    init(device: DeviceInfo, launcher: any ScrcpyLauncher,
         makeDecoder: @escaping @Sendable (@escaping @Sendable (VideoFrame) -> Void) -> any VideoDecoding,
         clipboardTimeout: Duration) {
        self.transport = OSAllocatedUnfairLock(initialState: Transport(device: device))
        self.launcher = launcher
        self.makeDecoder = makeDecoder
        self.clipboardTimeout = clipboardTimeout
        (events, continuation) = AsyncStream<SessionEvent>.makeStream()
    }

    deinit {
        continuation.finish()
    }

    // MARK: - 帧

    public nonisolated func latestFrame() -> VideoFrame? {
        frames.withLock { $0.latest }
    }

    public nonisolated func addFrameObserver(_ observer: @escaping @Sendable (VideoFrame) -> Void) -> FrameObserverToken {
        frames.withLock { s in
            s.nextObserverID += 1
            s.observers[s.nextObserverID] = observer
            return FrameObserverToken(id: s.nextObserverID)
        }
    }

    public nonisolated func removeFrameObserver(_ token: FrameObserverToken) {
        frames.withLock { _ = $0.observers.removeValue(forKey: token.id) }
    }

    /// 解码器回调（VT 线程）：不回调解码器。
    private nonisolated func deliver(_ frame: VideoFrame, run id: Int) {
        // 锁内取订阅者快照，锁外逐个回调，避免回调里增删订阅时死锁。
        let observers = frames.withLock { s -> [@Sendable (VideoFrame) -> Void] in
            guard s.runID == id else { return [] }
            s.latest = frame
            return Array(s.observers.values)
        }
        for observer in observers { observer(frame) }
    }

    // MARK: - 设备 / 传输

    public nonisolated func updateDevice(_ device: DeviceInfo) {
        transport.withLock { $0.device = device }
    }

    public nonisolated var activeSerial: String? {
        transport.withLock { $0.active }
    }

    // MARK: - 生命周期

    public func start() async {
        let stopsAtCall = stopRequests
        await serialized { await self.performStart(stopsAtCall: stopsAtCall) }
    }

    public func stop() async {
        stopRequests += 1
        launching?.cancel()
        await serialized { await self.performStop() }
    }

    /// 按调用顺序串行执行生命周期操作。
    private func serialized(_ operation: @escaping @Sendable () async -> Void) async {
        let previous = lifecycle
        let task = Task {
            await previous?.value
            await operation()
        }
        lifecycle = task
        await task.value
    }

    private func performStart(stopsAtCall: Int) async {
        // 之后有 stop 排在后面：这次 start 作废，由 stop 收尾。
        guard stopRequests == stopsAtCall else { return }
        if let teardown { await teardown.value }
        guard stopRequests == stopsAtCall else { return }
        switch state {
        case .connecting, .running: return
        case .idle, .disconnected, .failed: break
        }
        let device = transport.withLock { t in
            t.active = t.device.serial
            return t.device
        }
        nextRunID += 1
        let id = nextRunID
        // 新的 run：丢弃上一个 run 的最后一帧（断开期间保留它供窗口显示）。
        frames.withLock { s in
            s.latest = nil
            s.runID = id
        }
        emit(.connecting)

        let options = ScrcpyLaunchOptions.for(device.connection, scid: UInt32.random(in: 0...0x7fff_ffff))
        let serial = device.serial
        let launch = Task { [launcher] in try await launcher.launch(serial: serial, options: options) }
        launching = launch
        let result = await launch.result
        launching = nil
        let superseded = stopRequests != stopsAtCall

        let launched: LaunchedServer
        switch result {
        case .failure(let error):
            if !superseded { emit(.failed(error as? DeviceError ?? .connectionFailed("\(error)"))) }
            return
        case .success(let value):
            launched = value
        }
        guard !superseded else {
            // 启动期间被 stop：在 stop 返回之前清理掉这次迟到的启动。
            await launched.stop()
            return
        }

        let decoder = makeDecoder { [weak self] frame in self?.deliver(frame, run: id) }
        let connection = launched.connection
        let (writes, writer) = AsyncStream<Outgoing>.makeStream()
        let writerTask = Task { await Self.writeLoop(writes, control: connection.control) }
        run = Run(id: id, launched: launched, writer: writer, writerTask: writerTask)
        run?.tasks = [
            Task { await self.videoLoop(id, video: connection.video, decoder: decoder) },
            Task { await self.controlLoop(id, control: connection.control) },
            Task { await self.logLoop(id, logs: launched.logs) },
        ]
    }

    private func performStop() async {
        if let run {
            await endRun(run.id, with: .idle)
            return
        }
        if let teardown { await teardown.value }  // 断开清理中：先让 .disconnected 发出
        if state != .idle { emit(.idle) }
    }

    /// 结束 run：取消循环、恰好一次 launched.stop()，然后发出终态。并发调用会等待同一次清理。
    private func endRun(_ id: Int, with final: SessionState) async {
        guard let run, run.id == id else {
            await teardown?.value
            return
        }
        self.run = nil
        run.tasks.forEach { $0.cancel() }
        run.writer.finish()
        failWaiters(DeviceError.connectionFailed("会话已结束"))
        let task = Task {
            await run.launched.stop()
            await run.writerTask.value  // 队列里剩下的写都已完成或失败，等待中的 send 已返回
            self.finishTeardown(final)
        }
        teardown = task
        await task.value
    }

    private func finishTeardown(_ final: SessionState) {
        teardown = nil
        emit(final)
    }

    private func emit(_ newState: SessionState) {
        switch newState {
        case .idle, .disconnected, .failed: transport.withLock { $0.active = nil }
        case .connecting, .running: break
        }
        state = newState
        continuation.yield(.state(newState))
    }

    // MARK: - 循环

    private struct ProtocolError: Error {
        let error: DeviceError
    }

    private nonisolated func videoLoop(_ id: Int, video: any ByteStream, decoder: any VideoDecoding) async {
        let final: SessionState
        do {
            let codec = try await video.readExactly(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            guard codec == VideoCodecId.h264 else { throw ProtocolError(error: .connectionFailed("视频编码不受支持")) }
            while !Task.isCancelled {
                guard let header = VideoHeader.parse(try await video.readExactly(VideoHeader.length)) else {
                    throw ProtocolError(error: .connectionFailed("视频包头无效"))
                }
                switch header {
                case let .session(width, height):
                    guard width > 0, height > 0 else {
                        throw ProtocolError(error: .connectionFailed("视频尺寸无效（\(width)x\(height)）"))
                    }
                    decoder.reset()
                    await sessionStarted(id, width: width, height: height)
                case let .media(config, _, pts, size):
                    let payload = try await video.readExactly(size)
                    if config {
                        decoder.decode(config: payload)
                    } else {
                        decoder.decode(frame: payload, pts: pts)
                    }
                }
            }
            return
        } catch let failure as ProtocolError {
            final = .failed(failure.error)
        } catch {
            if Task.isCancelled { return }
            Self.logger.info("视频流结束：\(String(describing: error))")
            final = .disconnected
        }
        await endRun(id, with: final)
    }

    private func sessionStarted(_ id: Int, width: Int, height: Int) {
        guard run?.id == id else { return }
        run?.videoSize = (width, height)
        emit(.running(width: width, height: height))
    }

    private nonisolated func controlLoop(_ id: Int, control: any ByteStream) async {
        var decoder = DeviceMessageDecoder()
        do {
            while !Task.isCancelled {
                // ByteStream 只能定长读，按消息格式读出完整一条再交给解码器。
                var chunk = try await control.readExactly(1)
                switch chunk.first {
                case 0:
                    let length = try await control.readExactly(4)
                    let n = length.reduce(0) { $0 << 8 | Int($1) }
                    guard n <= Self.maxClipboardLength else { throw DeviceError.connectionFailed("剪切板消息过长：\(n)") }
                    chunk += length + (try await control.readExactly(n))
                case 1:
                    chunk += try await control.readExactly(8)
                default:
                    break  // 未知类型：交给解码器抛错
                }
                for message in try decoder.append(chunk) {
                    await handle(message, runID: id)
                }
            }
        } catch {
            if !Task.isCancelled { Self.logger.info("控制流结束：\(String(describing: error))") }
        }
    }

    private func handle(_ message: DeviceMessage, runID: Int) {
        guard run?.id == runID else { return }
        switch message {
        case let .clipboard(text):
            let waiters = clipboardWaiters
            clipboardWaiters.removeAll()
            for waiter in waiters.values {
                waiter.timeout.cancel()
                waiter.continuation.resume(returning: text)
            }
        case let .ackClipboard(sequence):
            guard let waiter = ackWaiters.removeValue(forKey: sequence) else { return }
            waiter.timeout.cancel()
            waiter.continuation.resume()
        }
    }

    private nonisolated func logLoop(_ id: Int, logs: AsyncStream<String>) async {
        for await line in logs {
            Self.logger.debug("scrcpy: \(line, privacy: .public)")
            if ScrcpyLog.isInjectPermissionError(line) {
                await reportInjectPermission(id)
            }
        }
    }

    private func reportInjectPermission(_ id: Int) {
        guard run?.id == id, run?.injectPermissionReported == false else { return }
        run?.injectPermissionReported = true
        continuation.yield(.injectPermissionDenied)
    }

    // MARK: - 输入

    public func send(_ action: InputAction) async {
        guard let run, let size = run.videoSize else { return }  // 不在 running：丢弃，不排队
        switch InputMapper.map(action, width: size.width, height: size.height) {
        case let .messages(messages):
            guard !messages.isEmpty else { return }
            // 同一动作的多条消息作为一次写入，入队顺序即到达顺序。
            let data = messages.reduce(into: Data()) { $0 += $1.encoded() }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                enqueue(data, to: run) { error in
                    if let error { Self.logger.error("发送控制消息失败：\(String(describing: error))") }
                    continuation.resume()
                }
            }
        case let .paste(text):
            do {
                try await setClipboard(text, paste: true)
            } catch {
                Self.logger.error("粘贴文本失败：\(String(describing: error))")
            }
        }
    }

    // MARK: - 剪切板

    public func getClipboard() async throws -> String {
        guard let run else { throw DeviceError.connectionFailed("会话未运行") }
        let id = nextWaiterID
        nextWaiterID += 1
        // 先登记等待者再入队写出，避免回应早于登记到达。
        return try await withCheckedThrowingContinuation { continuation in
            clipboardWaiters[id] = Waiter(continuation: continuation, timeout: Task {
                try? await Task.sleep(for: clipboardTimeout)
                guard !Task.isCancelled else { return }
                self.clipboardWaiters.removeValue(forKey: id)?.continuation.resume(throwing: DeviceError.timeout("读取剪切板"))
            })
            enqueue(ControlMessage.getClipboard(copyKey: 0).encoded(), to: run) { [weak self] error in
                if let error { await self?.failClipboardWaiter(id, error) }
            }
        }
    }

    public func setClipboard(_ text: String, paste: Bool) async throws {
        guard let run else { throw DeviceError.connectionFailed("会话未运行") }
        let sequence = nextSequence
        nextSequence += 1
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            ackWaiters[sequence] = Waiter(continuation: continuation, timeout: Task {
                try? await Task.sleep(for: clipboardTimeout)
                guard !Task.isCancelled else { return }
                self.ackWaiters.removeValue(forKey: sequence)?.continuation.resume(throwing: DeviceError.timeout("写入剪切板"))
            })
            enqueue(ControlMessage.setClipboard(sequence: sequence, text: text, paste: paste).encoded(), to: run) { [weak self] error in
                if let error { await self?.failAckWaiter(sequence, error) }
            }
        }
    }

    private func failClipboardWaiter(_ id: Int, _ error: any Error) {
        clipboardWaiters.removeValue(forKey: id)?.fail(error)
    }

    private func failAckWaiter(_ sequence: UInt64, _ error: any Error) {
        ackWaiters.removeValue(forKey: sequence)?.fail(error)
    }

    // MARK: - 写协程

    /// 同步入队（在 actor 上），保证调用顺序即写出顺序。
    private func enqueue(_ data: Data, to run: Run, done: @escaping @Sendable ((any Error)?) async -> Void) {
        if case .terminated = run.writer.yield(Outgoing(data: data, done: done)) {
            Task { await done(ByteStreamError.closed) }
        }
    }

    private static func writeLoop(_ writes: AsyncStream<Outgoing>, control: any ByteStream) async {
        for await item in writes {
            do {
                try await control.write(item.data)
                await item.done(nil)
            } catch {
                await item.done(error)
            }
        }
    }

    private func failWaiters(_ error: DeviceError) {
        let clipboard = clipboardWaiters, acks = ackWaiters
        clipboardWaiters.removeAll()
        ackWaiters.removeAll()
        clipboard.values.forEach { $0.fail(error) }
        acks.values.forEach { $0.fail(error) }
    }
}
