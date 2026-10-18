import DeviceCore
import Foundation

final class FakeSession: DeviceSession, @unchecked Sendable {
    let device: DeviceInfo
    init(device: DeviceInfo) { self.device = device }
    var events: AsyncStream<SessionEvent> { AsyncStream { $0.finish() } }
    func start() async {}
    func stop() async {}
    func send(_ action: InputAction) async {}
    func getClipboard() async throws -> String { "" }
    func setClipboard(_ text: String, paste: Bool) async throws {}
    func latestFrame() -> VideoFrame? { nil }
    func setFrameHandler(_ handler: @escaping @Sendable (VideoFrame) -> Void) {}
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
}
