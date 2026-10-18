import CoreMedia
import CoreVideo

public struct VideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    /// scrcpy 的 PTS（微秒时基）；来源不带时间戳时为 .invalid。
    public let presentationTime: CMTime

    public init(pixelBuffer: CVPixelBuffer, presentationTime: CMTime = .invalid) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
    }
}

/// addFrameObserver 返回的订阅凭据，用于退订。
public struct FrameObserverToken: Hashable, Sendable {
    public let id: Int

    public init(id: Int) { self.id = id }
}

public enum SessionState: Sendable, Equatable {
    case idle, connecting, running(width: Int, height: Int), disconnected, failed(DeviceError)
}

public enum SessionEvent: Sendable, Equatable {
    case state(SessionState)
    case injectPermissionDenied
    /// 设备主动推来的剪贴板内容（没有等待中的 getClipboard 时发出）。
    case clipboardChanged(String)
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
    /// 多订阅者：每个订阅者都收到每一帧（在解码线程回调，须自行切线程）。
    func addFrameObserver(_ observer: @escaping @Sendable (VideoFrame) -> Void) -> FrameObserverToken
    func removeFrameObserver(_ token: FrameObserverToken)
}
