import CoreVideo

public struct VideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer

    public init(pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
    }
}

public enum SessionState: Sendable, Equatable {
    case idle, connecting, running(width: Int, height: Int), disconnected, failed(DeviceError)
}

public enum SessionEvent: Sendable, Equatable {
    case state(SessionState)
    case injectPermissionDenied
}

public protocol DeviceSession: AnyObject, Sendable {
    /// 单订阅者（AppModel）
    var events: AsyncStream<SessionEvent> { get }
    /// 可在 disconnected/failed/idle 后再次调用
    func start() async
    func stop() async
    func send(_ action: InputAction) async
    func getClipboard() async throws -> String
    func setClipboard(_ text: String, paste: Bool) async throws
    func latestFrame() -> VideoFrame?
    func setFrameHandler(_ handler: @escaping @Sendable (VideoFrame) -> Void)
}
