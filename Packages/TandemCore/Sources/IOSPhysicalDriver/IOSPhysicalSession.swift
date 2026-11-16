import CoreVideo
import DeviceCore
import Foundation

public actor IOSPhysicalSession: DeviceSession {
    public nonisolated var events: AsyncStream<SessionEvent> { continuation.stream() }
    private nonisolated let continuation = USBEventChannel()
    private nonisolated let storage: USBSessionStorage
    private let launch: @Sendable (String) throws -> any USBHelperProcess
    private let requestTimeout: Duration
    private let textRequestTimeout: Duration
    private var generation = 0
    private var run: Run?
    private var teardown: Task<Void, Never>?
    private var stopRequests = 0
    private var nextRequest = 0
    private var pending: [Int: Waiter] = [:]
    private var ownership = USBTouchOwnership()
    // Includes the duration of an async acknowledgement, preventing same-source reentrancy.
    private var inputBusy = false
    private var exclusiveInput = false
    private var inputWaiters: [CheckedContinuation<Void, Never>] = []

    private struct Run {
        let generation: Int
        let process: any USBHelperProcess
        var reader: Task<Void, Never>?
        var videoReader: Task<Void, Never>?
        var writer: Task<Void, Never>?
        var outgoing: AsyncStream<Data>.Continuation?
        var firstFrameTimeout: Task<Void, Never>?
        var dimensions: Dimensions?
    }
    private struct Dimensions: Equatable { let width: Int; let height: Int }
    private struct Waiter {
        let continuation: CheckedContinuation<Void, any Error>
        let timeout: Task<Void, Never>
    }
    public init(device: DeviceInfo, helperURL: URL?) {
        storage = USBSessionStorage(device: device)
        requestTimeout = .seconds(5)
        textRequestTimeout = .seconds(8)
        launch = { udid in
            if let error = IOSPhysicalDriver.unavailabilityReason(helperURL: helperURL) { throw error }
            guard let helperURL else { throw DeviceError.unsupported("USB helper 不可用") }
            return try StdioUSBHelper(url: helperURL, udid: udid)
        }
    }
    init(device: DeviceInfo, launch: @escaping @Sendable (String) throws -> any USBHelperProcess,
         requestTimeout: Duration) {
        storage = USBSessionStorage(device: device)
        self.launch = launch
        self.requestTimeout = requestTimeout
        textRequestTimeout = requestTimeout
    }
    deinit {
        run?.reader?.cancel()
        run?.videoReader?.cancel()
        run?.writer?.cancel()
        run?.outgoing?.finish()
        run?.firstFrameTimeout?.cancel()
        run?.process.terminate()
        for waiter in pending.values {
            waiter.timeout.cancel()
            waiter.continuation.resume(throwing: protocolError("iPhone 会话已释放"))
        }
        continuation.finish()
    }
    public nonisolated var activeSerial: String? { storage.activeSerial }
    public nonisolated func updateDevice(_ device: DeviceInfo) { storage.updateDevice(device) }
    public nonisolated func latestFrame() -> VideoFrame? { storage.latestFrame() }
    public nonisolated func addFrameObserver(_ observer: @escaping @Sendable (VideoFrame) -> Void) -> FrameObserverToken { storage.add(observer) }
    public nonisolated func removeFrameObserver(_ token: FrameObserverToken) { storage.remove(token) }

    public func start() async {
        let stopsAtCall = stopRequests
        await teardown?.value
        guard stopsAtCall == stopRequests, run == nil else { return }
        teardown = nil
        generation += 1
        let id = generation
        let device = storage.begin(id)
        continuation.yield(.state(.connecting))
        do {
            let process = try launch(device.serial)
            let (writes, outgoing) = AsyncStream<Data>.makeStream()
            run = Run(generation: id, process: process, outgoing: outgoing)
            run?.writer = Task { [weak self] in
                do {
                    for await data in writes {
                        guard !Task.isCancelled else { return }
                        try await process.write(data)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.end(id, state: .failed(Self.deviceError(error)))
                }
            }
            run?.reader = Task { [weak self] in
                var decoder = USBMessageDecoder()
                do {
                    for await bytes in process.bytes {
                        guard !Task.isCancelled else { return }
                        for message in try decoder.append(bytes) { try await self?.receive(message, generation: id) }
                    }
                    guard !Task.isCancelled else { return }
                    try decoder.finish()
                    await self?.end(id, state: .disconnected)
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.end(id, state: .failed(Self.deviceError(error)))
                }
            }
            run?.videoReader = Task { [weak self] in
                do {
                    for try await frame in process.frames {
                        guard !Task.isCancelled else { return }
                        await self?.receiveVideo(frame, generation: id)
                    }
                    guard !Task.isCancelled else { return }
                    await self?.end(id, state: .disconnected)
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.end(id, state: .failed(Self.deviceError(error)))
                }
            }
            run?.firstFrameTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                await self?.end(id, state: .failed(.timeout("等待 iPhone 首帧")))
            }
        } catch {
            storage.clear(id)
            continuation.yield(.state(.failed(Self.deviceError(error))))
        }
    }
    public func stop() async {
        stopRequests += 1
        if let id = run?.generation { end(id, state: .idle) }
        else { storage.clear(generation); continuation.yield(.state(.idle)) }
        await teardown?.value
    }
    private func end(_ id: Int, state: SessionState) {
        guard let run, run.generation == id else { return }
        self.run = nil
        run.reader?.cancel()
        run.videoReader?.cancel()
        run.writer?.cancel()
        run.outgoing?.finish()
        run.firstFrameTimeout?.cancel()
        run.process.terminate()
        teardown = Task { await run.process.waitUntilExit() }
        storage.clear(id)
        ownership.reset()
        let error: DeviceError
        if case let .failed(failure) = state { error = failure }
        else { error = protocolError("iPhone USB 会话已结束") }
        let waiting = pending
        pending.removeAll()
        for waiter in waiting.values { waiter.timeout.cancel(); waiter.continuation.resume(throwing: error) }
        continuation.yield(.state(state))
    }
    private func receiveVideo(_ frame: VideoFrame, generation id: Int) {
        guard run?.generation == id else { return }
        storage.deliver(frame, generation: id)
        let dimensions = Dimensions(width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer))
        if run?.dimensions != dimensions {
            run?.dimensions = dimensions
            run?.firstFrameTimeout?.cancel()
            continuation.yield(.state(.running(width: dimensions.width, height: dimensions.height)))
        }
    }
    private func receive(_ message: USBMessage, generation id: Int) throws {
        guard run?.generation == id else { return }
        if message.event == "input_ack", let requestID = message.id {
            guard let waiter = pending.removeValue(forKey: requestID) else { return } // Unknown ack is never replayed.
            waiter.timeout.cancel()
            if message.sent == true, message.error == nil { waiter.continuation.resume() }
            else {
                let error = Self.inputError(message.error)
                waiter.continuation.resume(throwing: error)
                end(id, state: .failed(error))
            }
            return
        }
        switch message.event {
        case "ready", "video_started", "frame", "video_stats", "summary": break
        case "disconnected": end(id, state: .disconnected)
        case "error": throw protocolError(message.error ?? message.message ?? "iPhone USB helper 失败")
        default: break // Forward-compatible telemetry does not change session state.
        }
    }
    private func request(_ request: USBRequest, generation expected: Int, timeout: Duration? = nil) async throws {
        try Task.checkCancellation()
        guard let run, run.generation == expected, run.dimensions != nil else { throw protocolError("iPhone 画面尚未就绪") }
        nextRequest += 1
        let requestID = nextRequest
        var request = request
        request.id = requestID
        let data = try request.encodedLine()
        let timeoutDuration = timeout ?? requestTimeout
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: timeoutDuration)
                    guard !Task.isCancelled else { return }
                    await self?.requestTimedOut(requestID, generation: expected)
                }
                pending[requestID] = Waiter(continuation: continuation, timeout: timeout)
                if case .terminated = run.outgoing?.yield(data) { end(expected, state: .failed(protocolError("iPhone 输入通道关闭"))) }
            }
        } onCancel: { Task { await self.cancelRequest(requestID, generation: expected) } }
    }
    private func requestTimedOut(_ id: Int, generation: Int) {
        guard pending[id] != nil else { return }
        // Delivery is unknown. Closing this run releases its contact; do not retry.
        end(generation, state: .failed(DeviceError(code: .TIMEOUT, message: "iPhone 输入确认超时；设备执行状态未知，未重试")))
    }
    private func cancelRequest(_ id: Int, generation: Int) {
        guard let waiter = pending.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        end(generation, state: .idle)
        waiter.continuation.resume(throwing: CancellationError())
    }
    public func send(_ action: InputAction) async {
        do { try await sendChecked(action) }
        catch let error as DeviceError where error.code == .UNSUPPORTED || error.code == .INVALID_ARGUMENT || error.code == .AI_LOCKED { }
        catch is CancellationError { }
        catch { if let id = run?.generation { end(id, state: .failed(Self.deviceError(error))) } }
    }
    public func sendChecked(_ action: InputAction) async throws {
        try await sendInput(action)
    }
    public func replaceText(_ text: String) async throws {
        try await sendInput(.text(text), replaceExisting: true)
    }
    private func sendInput(_ action: InputAction, replaceExisting: Bool = false) async throws {
        try Task.checkCancellation()
        guard let id = run?.generation, run?.dimensions != nil else { throw protocolError("iPhone 画面尚未就绪") }
        if inputBusy {
            // Same-source touch packets preserve order while awaiting a prior ACK.
            // A scroll owns its full path, and unrelated sources cannot join it.
            guard !exclusiveInput, case let .touch(_, _, pointer) = action,
                  ownership.owner == pointer, inputWaiters.count < 256 else {
                throw DeviceError(code: .AI_LOCKED, message: "触控输入正在处理")
            }
            await withCheckedContinuation { inputWaiters.append($0) }
        } else { inputBusy = true }
        defer {
            exclusiveInput = false
            if inputWaiters.isEmpty { inputBusy = false }
            else { inputWaiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        guard run?.generation == id else { throw protocolError("iPhone 会话已改变") }
        switch action {
        case let .touch(phase, point, pointer): try await touch(phase, point: point, pointer: pointer, generation: id)
        case let .key(key):
            guard ownership.owner == nil else { throw DeviceError(code: .AI_LOCKED, message: "触控手势进行中") }
            exclusiveInput = true
            switch key {
            case .home: try await request(USBRequest(op: "button", button: "home"), generation: id)
            case .enter, .delete, .tab, .up, .down, .left, .right:
                try await request(USBRequest(op: "key", key: key.rawValue), generation: id)
            default: throw DeviceError.unsupported("iPhone USB 不支持此按键")
            }
        case let .text(text):
            guard ownership.owner == nil else { throw DeviceError(code: .AI_LOCKED, message: "触控手势进行中") }
            exclusiveInput = true
            // Text insertion never submits; callers must issue an explicit Enter separately.
            try await request(USBRequest(op: "text", text: text, replace: replaceExisting ? true : nil), generation: id, timeout: textRequestTimeout)
        case let .scroll(point, dx, dy):
            exclusiveInput = true
            let start = try Self.point(point)
            guard dx.isFinite, dy.isFinite else { throw DeviceError(code: .INVALID_ARGUMENT, message: "滚动量必须是有限数值") }
            guard dx != 0 || dy != 0 else { return }
            let last = try Self.point(.init(x: start.x - min(0.25, max(-0.25, dx * 0.025)), y: start.y + min(0.25, max(-0.25, dy * 0.025))))
            try await touch(.down, point: start, pointer: .finger, generation: id)
            do {
                for index in 1...5 {
                    try await Task.sleep(for: .milliseconds(12))
                    let t = Double(index) / 5
                    try await touch(.move, point: .init(x: start.x + (last.x - start.x) * t, y: start.y + (last.y - start.y) * t), pointer: .finger, generation: id)
                }
                try await touch(.up, point: last, pointer: .finger, generation: id)
            } catch {
                if run?.generation == id, ownership.owner == .finger {
                    // Only this acquired contact may be released; never another source's.
                    try? await touch(.up, point: last, pointer: .finger, generation: id)
                }
                throw error
            }
        }
    }
    private func touch(_ phase: TouchPhase, point: NormalizedPoint, pointer: TouchPointer, generation id: Int) async throws {
        let point = try Self.point(point)
        let oldOwner = ownership
        try ownership.begin(phase, pointer: pointer)
        let name = switch phase { case .down: "down"; case .move: "move"; case .up: "up" }
        do {
            try await request(USBRequest(op: "touch", phase: name, x: point.x, y: point.y), generation: id)
            ownership.finish(phase)
        } catch {
            if run?.generation == id { ownership = oldOwner }
            throw error
        }
    }
    private static func point(_ point: NormalizedPoint) throws -> NormalizedPoint {
        guard point.x.isFinite, point.y.isFinite else { throw DeviceError(code: .INVALID_ARGUMENT, message: "触控坐标必须是有限数值") }
        return .init(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
    }
    public func getClipboard() async throws -> String { throw DeviceError.unsupported("iPhone USB 暂不支持剪贴板") }
    public func setClipboard(_ text: String, paste: Bool) async throws { throw DeviceError.unsupported("iPhone USB 暂不支持剪贴板") }
    private static func inputError(_ message: String?) -> DeviceError {
        switch message {
        case "native pasteboard service unavailable": .unsupported("iPhone 原生文本写入服务不可用")
        case "native keyboard service unavailable", "unsupported key or native keyboard service unavailable":
            .unsupported("iPhone 原生键盘服务或所选按键不可用")
        case "native text input timeout; device effect uncertain":
            DeviceError(code: .TIMEOUT, message: "iPhone 文本输入超时；设备执行状态未知，未重试")
        case "text must contain 1...8192 UTF-8 bytes", "text must not contain NUL":
            DeviceError(code: .INVALID_ARGUMENT, message: "iPhone 文本须为非空、不含 NUL 且不超过 8192 UTF-8 字节")
        default: protocolError(message ?? "iPhone 输入未确认发送")
        }
    }
    private static func deviceError(_ error: any Error) -> DeviceError {
        error as? DeviceError ?? protocolError("iPhone USB 连接失败：\(error.localizedDescription)")
    }
}

private final class USBSessionStorage: @unchecked Sendable {
    private let lock = NSLock()
    private var device: DeviceInfo
    private var active: String?
    private var generation = 0
    private var latest: VideoFrame?
    private var nextObserver = 0
    private var observers: [Int: @Sendable (VideoFrame) -> Void] = [:]
    init(device: DeviceInfo) { self.device = device }
    var activeSerial: String? { lock.withLock { active } }
    func updateDevice(_ device: DeviceInfo) { lock.withLock { self.device = device } }
    func latestFrame() -> VideoFrame? { lock.withLock { latest } }
    func begin(_ id: Int) -> DeviceInfo {
        lock.withLock {
            generation = id
            active = device.serial
            latest = nil
            return device
        }
    }
    func clear(_ id: Int) {
        lock.withLock {
            guard generation == id else { return }
            active = nil
            latest = nil
        }
    }
    func add(_ observer: @escaping @Sendable (VideoFrame) -> Void) -> FrameObserverToken {
        lock.withLock {
            nextObserver += 1
            observers[nextObserver] = observer
            return FrameObserverToken(id: nextObserver)
        }
    }
    func remove(_ token: FrameObserverToken) { lock.withLock { _ = observers.removeValue(forKey: token.id) } }
    func deliver(_ frame: VideoFrame, generation id: Int) {
        let callbacks: [@Sendable (VideoFrame) -> Void] = lock.withLock {
            guard generation == id, active != nil else { return [] }
            latest = frame
            return Array(observers.values)
        }
        for callback in callbacks { callback(frame) }
    }
}

/// Cached sessions survive window close/reopen. Each new AppModel consumer obtains
/// a fresh stream: cancelling the previous iterator must not poison future runs.
private final class USBEventChannel: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var current: AsyncStream<SessionEvent>.Continuation?
    private var subscription = 0
    private var lastState: SessionEvent = .state(.idle)
    func stream() -> AsyncStream<SessionEvent> {
        let (stream, output) = AsyncStream<SessionEvent>.makeStream()
        let (old, id) = lock.withLock {
            let old = current
            current = output
            subscription += 1
            // Replay inside the same lock as publication, preserving state order.
            output.yield(lastState)
            return (old, subscription)
        }
        old?.finish()
        output.onTermination = { [weak self] _ in self?.remove(id) }
        return stream
    }
    private func remove(_ id: Int) { lock.withLock { if subscription == id { current = nil } } }
    func yield(_ event: SessionEvent) {
        lock.withLock {
            if case .state = event { lastState = event }
            current?.yield(event)
        }
    }
    func finish() {
        let old = lock.withLock { let old = current; current = nil; return old }
        old?.finish()
    }
}
