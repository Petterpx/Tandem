import DeviceCore
import Foundation

final class FakeSession: DeviceSession, @unchecked Sendable {
    private let lock = NSLock()
    private var _device: DeviceInfo
    var device: DeviceInfo { lock.withLock { _device } }
    init(device: DeviceInfo) { _device = device }
    func updateDevice(_ device: DeviceInfo) { lock.withLock { _device = device } }
    var activeSerial: String? { nil }
    var events: AsyncStream<SessionEvent> { AsyncStream { $0.finish() } }
    func start() async {}
    func stop() async {}
    func send(_ action: InputAction) async {}
    func getClipboard() async throws -> String { "" }
    func setClipboard(_ text: String, paste: Bool) async throws {}
    func latestFrame() -> VideoFrame? { nil }
    func addFrameObserver(_ observer: @escaping @Sendable (VideoFrame) -> Void) -> FrameObserverToken { FrameObserverToken(id: 0) }
    func removeFrameObserver(_ token: FrameObserverToken) {}
}

final class FakeActions: DeviceActions, @unchecked Sendable {
    let serial: String
    init(serial: String) { self.serial = serial }
    func screenshot() async throws -> Data { Data() }
    func uiTree() async throws -> UITree { UITree(screen: CGSize(width: 1080, height: 2400), elements: []) }
}

final class FakeDriver: DeviceDriver, @unchecked Sendable {
    private let lock = NSLock()
    private var _made = 0
    private let stream: AsyncStream<[DeviceInfo]>
    let continuation: AsyncStream<[DeviceInfo]>.Continuation

    init() {
        (stream, continuation) = AsyncStream<[DeviceInfo]>.makeStream()
    }

    var madeCount: Int { lock.withLock { _made } }
    func deviceSnapshots() -> AsyncStream<[DeviceInfo]> { stream }
    func makeSession(for device: DeviceInfo) -> any DeviceSession {
        lock.withLock { _made += 1 }
        return FakeSession(device: device)
    }
    func makeActions(for device: DeviceInfo) -> any DeviceActions { FakeActions(serial: device.serial) }
}
