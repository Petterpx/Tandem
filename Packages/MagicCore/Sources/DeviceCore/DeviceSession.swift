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
    /// 设备信息更新（如首选传输从 Wi-Fi 换成 USB）。不影响进行中的 run；之后每次 start 都使用最新的 serial 与传输方式。
    func updateDevice(_ device: DeviceInfo)
    /// 当前 run（connecting / running）所用的 adb serial；没有进行中的 run 时为 nil。
    var activeSerial: String? { get }
    /// 可在 disconnected/failed/idle 后再次调用
    func start() async
    func stop() async
    func send(_ action: InputAction) async
    func getClipboard() async throws -> String
    func setClipboard(_ text: String, paste: Bool) async throws
    func latestFrame() -> VideoFrame?
    func setFrameHandler(_ handler: @escaping @Sendable (VideoFrame) -> Void)
}
