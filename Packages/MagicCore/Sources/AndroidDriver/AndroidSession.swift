import DeviceCore
import Foundation
import os

/// 一台 Android 设备的 scrcpy 会话：启动服务端、读视频流、发控制消息、处理断开。
///
/// 每次 `start()` 是一个 run（新的 scid、新的服务端进程）；run 结束时恰好调用一次 `launched.stop()`，
/// 并恰好发出一次终态（`.disconnected` / `.failed` / `.idle`）。
public actor AndroidSession: DeviceSession {
    public nonisolated let events: AsyncStream<SessionEvent>
    private nonisolated let continuation: AsyncStream<SessionEvent>.Continuation
    private nonisolated let frames = OSAllocatedUnfairLock(initialState: FrameState())

    private struct FrameState: Sendable {
        var latest: VideoFrame?
        var handler: (@Sendable (VideoFrame) -> Void)?
    }

    private struct Run {
        let id: Int
        let launched: LaunchedServer
        var tasks: [Task<Void, Never>] = []
        var videoSize: (width: Int, height: Int)?
        var injectPermissionReported = false
        var control: any ByteStream { launched.connection.control }
    }

    private struct Waiter<T: Sendable> {
        let continuation: CheckedContinuation<T, any Error>
        let timeout: Task<Void, Never>

        func fail(_ error: any Error) {
            timeout.cancel()
            continuation.resume(throwing: error)
        }
    }

    private static let logger = Logger(subsystem: "dev.magicdevx", category: "AndroidSession")
    private static let maxClipboardLength = 1 << 18

    private let device: DeviceInfo
    private let launcher: any ScrcpyLauncher
    private let makeDecoder: @Sendable (@escaping @Sendable (VideoFrame) -> Void) -> any VideoDecoding
    private let clipboardTimeout: Duration

    private var state: SessionState = .idle
    /// 每次 start/stop 自增；launch 返回时据此判断期间是否被 stop。
    private var generation = 0
    private var run: Run?
    /// 进行中的 launch；stop 时取消，避免握手卡住时 start 永远不返回。
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
        self.device = device
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

    public nonisolated func setFrameHandler(_ handler: @escaping @Sendable (VideoFrame) -> Void) {
        frames.withLock { $0.handler = handler }
    }

    /// 解码器回调（VT 线程）：不回调解码器。
    private nonisolated func deliver(_ frame: VideoFrame) {
        let handler = frames.withLock { s in
            s.latest = frame
            return s.handler
        }
        handler?(frame)
    }

    // MARK: - 生命周期

    public func start() async {
        if let teardown { await teardown.value }
        switch state {
        case .connecting, .running: return
        case .idle, .disconnected, .failed: break
        }
        generation += 1
        let gen = generation
        emit(.connecting)

        let options = ScrcpyLaunchOptions.for(device.connection, scid: UInt32.random(in: 0...0x7fff_ffff))
        let launch = Task { [launcher, device] in try await launcher.launch(serial: device.id, options: options) }
        launching = launch
        let launched: LaunchedServer
        do {
            launched = try await launch.value
        } catch {
            guard generation == gen else { return }  // 期间已 stop
            launching = nil
            emit(.failed(error as? DeviceError ?? .connectionFailed("\(error)")))
            return
        }
        guard generation == gen else {  // 期间已 stop：丢弃这次启动
            await launched.stop()
            return
        }
        launching = nil

        let decoder = makeDecoder { [weak self] frame in self?.deliver(frame) }
        let connection = launched.connection
        run = Run(id: gen, launched: launched)
        run?.tasks = [
            Task { await self.videoLoop(gen, video: connection.video, decoder: decoder) },
            Task { await self.controlLoop(gen, control: connection.control) },
            Task { await self.logLoop(gen, logs: launched.logs) },
        ]
    }

    public func stop() async {
        generation += 1  // 让进行中的 launch 作废
        launching?.cancel()
        launching = nil
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
        failWaiters(DeviceError.connectionFailed("会话已结束"))
        let task = Task {
            await run.launched.stop()
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
            // 一次写出，保证同一动作的多条消息不被其它写入穿插。
            let data = messages.reduce(into: Data()) { $0 += $1.encoded() }
            do {
                try await run.control.write(data)
            } catch {
                Self.logger.error("发送控制消息失败：\(String(describing: error))")
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
        // 先登记等待者再写出，避免回应早于登记到达。
        return try await withCheckedThrowingContinuation { continuation in
            clipboardWaiters[id] = Waiter(continuation: continuation, timeout: Task {
                try? await Task.sleep(for: clipboardTimeout)
                guard !Task.isCancelled else { return }
                self.clipboardWaiters.removeValue(forKey: id)?.continuation.resume(throwing: DeviceError.timeout("读取剪切板"))
            })
            Task {
                do {
                    try await run.control.write(ControlMessage.getClipboard(copyKey: 0).encoded())
                } catch {
                    self.clipboardWaiters.removeValue(forKey: id)?.fail(error)
                }
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
            Task {
                do {
                    try await run.control.write(ControlMessage.setClipboard(sequence: sequence, text: text, paste: paste).encoded())
                } catch {
                    self.ackWaiters.removeValue(forKey: sequence)?.fail(error)
                }
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
