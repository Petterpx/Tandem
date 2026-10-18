import CoreMedia
import CoreVideo
import DeviceCore
import Foundation

/// App 测试用的会话替身：可推帧、推事件、设定剪贴板结果并记录写入。
final class FakeDeviceSession: DeviceSession, @unchecked Sendable {
    private let lock = NSLock()
    private var observers: [Int: @Sendable (VideoFrame) -> Void] = [:]
    private var nextToken = 1
    private var nextPTS = 0
    private var _clipboardResult: Result<String, any Error> = .success("")
    private var _setError: (any Error)?
    private var _setCalls: [(text: String, paste: Bool)] = []
    private var _latest: VideoFrame?
    private let continuation: AsyncStream<SessionEvent>.Continuation
    let events: AsyncStream<SessionEvent>

    init() {
        (events, continuation) = AsyncStream<SessionEvent>.makeStream()
    }

    /// getClipboard 的返回结果。
    var clipboardResult: Result<String, any Error> {
        get { lock.withLock { _clipboardResult } }
        set { lock.withLock { _clipboardResult = newValue } }
    }
    /// 设置后 setClipboard 抛出该错误（不记录调用）。
    var setClipboardError: (any Error)? {
        get { lock.withLock { _setError } }
        set { lock.withLock { _setError = newValue } }
    }
    /// setClipboard 的调用记录。
    var setClipboardCalls: [(text: String, paste: Bool)] { lock.withLock { _setCalls } }
    var observerCount: Int { lock.withLock { observers.count } }

    func pushEvent(_ event: SessionEvent) { continuation.yield(event) }

    /// 推 BGRA 帧，PTS 跨批次连续递增。每帧间隔约 10ms 模拟实时送帧（录制器在编码器未就绪时会丢帧）。
    func pushFrames(count: Int, size: CGSize, fps: Int) async {
        for _ in 0..<count {
            let pts = lock.withLock { () -> CMTime in
                defer { nextPTS += 1 }
                return CMTime(value: CMTimeValue(nextPTS), timescale: CMTimeScale(fps))
            }
            let frame = Self.makeFrame(size: size, pts: pts)
            let current = lock.withLock { () -> [@Sendable (VideoFrame) -> Void] in
                _latest = frame
                return Array(observers.values)
            }
            current.forEach { $0(frame) }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    static func makeFrame(size: CGSize, pts: CMTime) -> VideoFrame {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &buffer)
        let pb = buffer!
        CVPixelBufferLockBaseAddress(pb, [])
        memset(CVPixelBufferGetBaseAddress(pb)!, 0x80, CVPixelBufferGetBytesPerRow(pb) * Int(size.height))
        CVPixelBufferUnlockBaseAddress(pb, [])
        return VideoFrame(pixelBuffer: pb, presentationTime: pts)
    }

    func updateDevice(_ device: DeviceInfo) {}
    var activeSerial: String? { nil }
    func start() async {}
    func stop() async {}
    func send(_ action: InputAction) async {}
    func getClipboard() async throws -> String { try clipboardResult.get() }
    func setClipboard(_ text: String, paste: Bool) async throws {
        if let error = setClipboardError { throw error }
        lock.withLock { _setCalls.append((text, paste)) }
    }
    func latestFrame() -> VideoFrame? { lock.withLock { _latest } }
    func addFrameObserver(_ observer: @escaping @Sendable (VideoFrame) -> Void) -> FrameObserverToken {
        lock.withLock {
            let id = nextToken
            nextToken += 1
            observers[id] = observer
            return FrameObserverToken(id: id)
        }
    }
    func removeFrameObserver(_ token: FrameObserverToken) {
        lock.withLock { _ = observers.removeValue(forKey: token.id) }
    }
}
