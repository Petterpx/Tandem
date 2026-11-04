import CoreVideo
import DeviceCore
import Foundation

public actor IOSSimulatorSession: DeviceSession {
    public nonisolated let events: AsyncStream<SessionEvent>
    private nonisolated let continuation: AsyncStream<SessionEvent>.Continuation
    private nonisolated let storage: SimulatorSessionStorage
    private let launch: @Sendable (String) throws -> any SimulatorHelperProcess
    private let requestTimeout: Duration
    private let textRequestTimeout: Duration
    private var generation = 0
    private var run: Run?
    private var teardown: Task<Void, Never>?
    private var stopRequests = 0
    private var nextRequest = 0
    private var pending: [Int: Waiter] = [:]

    private struct Run {
        let generation: Int
        let process: any SimulatorHelperProcess
        var reader: Task<Void, Never>?
        var videoReader: Task<Void, Never>?
        var writer: Task<Void, Never>?
        var outgoing: AsyncStream<Data>.Continuation?
        var firstFrameTimeout: Task<Void, Never>?
        var dimensions: Dimensions?
        var hasFrame: Bool { dimensions != nil }
    }
    private struct Dimensions: Equatable { let width: Int; let height: Int }
    private struct Waiter {
        let continuation: CheckedContinuation<SimulatorMessage, any Error>
        let timeout: Task<Void, Never>
        let usesExtendedTimeout: Bool
    }

    public init(device: DeviceInfo, helperURL: URL?) {
        storage = SimulatorSessionStorage(device: device)
        requestTimeout = .seconds(5)
        textRequestTimeout = .seconds(25)
        launch = { udid in
            if let error = IOSSimulatorDriver.unavailabilityReason(helperURL: helperURL) { throw error }
            guard let helperURL else { throw DeviceError.unsupported("未找到模拟器 helper") }
            return try StdioSimulatorHelper(url: helperURL, udid: udid)
        }
        (events, continuation) = AsyncStream.makeStream()
    }

    init(device: DeviceInfo, launch: @escaping @Sendable (String) throws -> any SimulatorHelperProcess,
         requestTimeout: Duration, textRequestTimeout: Duration? = nil) {
        storage = SimulatorSessionStorage(device: device)
        self.launch = launch
        self.requestTimeout = requestTimeout
        self.textRequestTimeout = textRequestTimeout ?? requestTimeout
        (events, continuation) = AsyncStream.makeStream()
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
            waiter.continuation.resume(throwing: DeviceError(code: .CONNECTION_FAILED, message: "模拟器会话已释放"))
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
                var decoder = SimulatorMessageDecoder()
                do {
                    for await bytes in process.bytes {
                        guard !Task.isCancelled else { return }
                        for message in try decoder.append(bytes) { try await self?.receive(message, generation: id) }
                    }
                    guard !Task.isCancelled else { return }
                    try decoder.finish()
                    await self?.end(id, state: .failed(DeviceError(code: .CONNECTION_FAILED, message: "模拟器 helper 已退出")))
                } catch {
                    guard !Task.isCancelled else { return }
                    await self?.end(id, state: .failed(Self.deviceError(error)))
                }
            }
            if let frames = process.videoFrames {
                run?.videoReader = Task { [weak self] in
                    do {
                        for try await frame in frames {
                            guard !Task.isCancelled else { return }
                            await self?.receiveVideo(frame, generation: id)
                        }
                    } catch {
                        guard !Task.isCancelled else { return }
                        await self?.end(id, state: .failed(Self.deviceError(error)))
                    }
                }
            }
            run?.firstFrameTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                await self?.end(id, state: .failed(.timeout("等待模拟器首帧")))
            }
        } catch {
            storage.clear(id)
            continuation.yield(.state(.failed(Self.deviceError(error))))
        }
    }

    public func stop() async {
        stopRequests += 1
        if let id = run?.generation { end(id, state: .idle) }
        else {
            storage.clear(generation)
            continuation.yield(.state(.idle))
        }
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
        let error: DeviceError
        if case let .failed(failure) = state { error = failure }
        else { error = DeviceError(code: .CONNECTION_FAILED, message: "模拟器会话已结束") }
        let waiting = pending
        pending.removeAll()
        for waiter in waiting.values {
            waiter.timeout.cancel()
            waiter.continuation.resume(throwing: error)
        }
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

    private func receive(_ message: SimulatorMessage, generation id: Int) throws {
        guard run?.generation == id else { return }
        if let requestID = message.id {
            guard let waiter = pending.removeValue(forKey: requestID) else { return }
            waiter.timeout.cancel()
            if let error = message.deviceError { waiter.continuation.resume(throwing: error) }
            else if message.ok == true { waiter.continuation.resume(returning: message) }
            else {
                let error = DeviceError(code: .CONNECTION_FAILED, message: "模拟器 helper 返回无效确认")
                waiter.continuation.resume(throwing: error)
                throw error
            }
            return
        }
        switch message.event {
        case "ready": break
        case "frame":
            let frame = try SimulatorFrameDecoder.decode(message)
            storage.deliver(frame, generation: id)
            let dimensions = Dimensions(width: message.width!, height: message.height!)
            if run?.dimensions != dimensions {
                run?.dimensions = dimensions
                run?.firstFrameTimeout?.cancel()
                continuation.yield(.state(.running(width: dimensions.width, height: dimensions.height)))
            }
        case "error": throw message.deviceError ?? DeviceError(code: .CONNECTION_FAILED, message: "模拟器 helper 失败")
        default: throw DeviceError(code: .CONNECTION_FAILED, message: "模拟器 helper 返回未知事件")
        }
    }

    private func request(_ request: SimulatorRequest, generation expected: Int? = nil) async throws -> SimulatorMessage {
        // An already cancelled operation must not enqueue input or trigger the active
        // request cancellation path, which tears down a possibly applied native touch.
        try Task.checkCancellation()
        guard let run, run.hasFrame, expected == nil || expected == run.generation else { throw DeviceError(code: .CONNECTION_FAILED, message: "模拟器画面尚未就绪") }
        nextRequest += 1
        let requestID = nextRequest
        var outgoing = request
        outgoing.id = requestID
        var data = try JSONEncoder().encode(outgoing)
        guard data.count <= 32 * 1024 * 1024 else { throw DeviceError(code: .INVALID_ARGUMENT, message: "模拟器命令超过大小限制") }
        data.append(10)
        // Native menu paste and the shared host-clipboard lock can take longer than
        // ordinary HID input. Commands queued behind that work need the same budget.
        // Propagate it through the pending queue until every acknowledgement arrives.
        let usesExtendedTimeout = request.command == "text"
            || (request.command == "clipboard_set" && request.paste == true)
            || pending.values.contains(where: \.usesExtendedTimeout)
        let timeoutDuration = usesExtendedTimeout ? max(textRequestTimeout, requestTimeout) : requestTimeout
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { [weak self] in
                    try? await Task.sleep(for: timeoutDuration)
                    guard !Task.isCancelled else { return }
                    await self?.requestTimedOut(requestID, generation: run.generation)
                }
                pending[requestID] = Waiter(continuation: continuation, timeout: timeout, usesExtendedTimeout: usesExtendedTimeout)
                if case .terminated = run.outgoing?.yield(data) {
                    end(run.generation, state: .failed(DeviceError(code: .CONNECTION_FAILED, message: "模拟器命令通道已关闭")))
                }
            }
        } onCancel: {
            Task { await self.cancelRequest(requestID, generation: run.generation) }
        }
    }

    private func requestTimedOut(_ id: Int, generation: Int) {
        guard pending[id] != nil else { return }
        end(generation, state: .failed(.timeout("模拟器命令")))
    }
    private func cancelRequest(_ id: Int, generation: Int) {
        let waiter = pending.removeValue(forKey: id)
        waiter?.timeout.cancel()
        // Cancellation may race the ack. The native operation can already have happened;
        // closing this generation releases its touch even if its waiter has just completed.
        end(generation, state: .idle)
        waiter?.continuation.resume(throwing: CancellationError())
    }

    public func send(_ action: InputAction) async {
        let generation = run?.generation
        do { try await sendChecked(action) }
        catch let error as DeviceError where error.code == .UNSUPPORTED || error.code == .INVALID_ARGUMENT || error.code == .AI_LOCKED { }
        catch is CancellationError { }
        catch {
            if let generation { end(generation, state: .failed(Self.deviceError(error))) }
        }
    }

    public func sendChecked(_ action: InputAction) async throws {
        let generation = run?.generation
        switch action {
        case let .touch(phase, point, pointer):
            let phaseName = switch phase { case .down: "down"; case .move: "move"; case .up: "up" }
            _ = try await request(SimulatorInput.touch(phaseName, at: point, pointer: pointer), generation: generation)
        case let .key(key):
            guard key.isSupported(on: .ios) else { throw DeviceError.unsupported("iOS 模拟器不支持 \(key.rawValue) 按键") }
            _ = try await request(SimulatorRequest(command: "key", key: key.rawValue), generation: generation)
        case let .text(text): _ = try await request(SimulatorRequest(command: "text", text: text), generation: generation)
        case let .scroll(point, dx, dy):
            let points = try SimulatorInput.scrollPoints(at: point, dx: dx, dy: dy)
            guard dx != 0 || dy != 0, let first = points.first, let last = points.last else { return }
            _ = try await request(SimulatorInput.touch("down", at: first, pointer: .finger), generation: generation)
            do {
                for point in points.dropFirst() {
                    try await Task.sleep(for: .milliseconds(12))
                    _ = try await request(SimulatorInput.touch("move", at: point, pointer: .finger), generation: generation)
                }
                _ = try await request(SimulatorInput.touch("up", at: last, pointer: .finger), generation: generation)
            } catch {
                // Best effort only releases this source's touch; helper enforces ownership.
                _ = try? await request(SimulatorInput.touch("up", at: last, pointer: .finger), generation: generation)
                throw error
            }
        }
    }

    func videoStatistics() async throws -> [String: UInt64]? {
        try await request(SimulatorRequest(command: "video_stats")).stats
    }

    public func getClipboard() async throws -> String {
        let response = try await request(SimulatorRequest(command: "clipboard_get"))
        guard let text = response.text else { throw DeviceError(code: .CONNECTION_FAILED, message: "模拟器剪贴板响应缺少文本") }
        return text
    }
    public func setClipboard(_ text: String, paste: Bool) async throws {
        _ = try await request(SimulatorRequest(command: "clipboard_set", text: text, paste: paste))
    }
    private static func deviceError(_ error: any Error) -> DeviceError {
        error as? DeviceError ?? DeviceError(code: .CONNECTION_FAILED, message: "模拟器连接失败：\(error.localizedDescription)")
    }
}

private final class SimulatorSessionStorage: @unchecked Sendable {
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
