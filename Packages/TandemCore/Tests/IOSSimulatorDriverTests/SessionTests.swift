import CoreVideo
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
import DeviceCore
@testable import IOSSimulatorDriver

@Suite struct SessionTests {
    let device = DeviceInfo(serial: "3B76F05C-3449-4D26-A84F-BAB414513611", platform: .ios, name: "iPhone", state: .connected, connection: .simulator)

    @Test func readyNeedsDecodedFirstFrameAndEOFRemovesFrame() async throws {
        let helper = FakeHelper()
        let session = IOSSimulatorSession(device: device, launch: { _ in helper }, requestTimeout: .milliseconds(100))
        await session.start()
        helper.emit(#"{"event":"ready"}"#)
        #expect(session.latestFrame() == nil)
        helper.frame()
        try await eventually { session.latestFrame() != nil }
        #expect(CVPixelBufferGetIOSurface(try #require(session.latestFrame()).pixelBuffer) != nil)
        helper.finish()
        try await eventually { session.activeSerial == nil }
        #expect(session.latestFrame() == nil)
    }

    @Test func rotationPublishesNewRunningDimensions() async throws {
        let helper = FakeHelper()
        let session = IOSSimulatorSession(device: device, launch: { _ in helper }, requestTimeout: .seconds(1))
        let states = StateLog()
        let observer = Task { for await event in session.events { if case let .state(state) = event { states.append(state) } } }
        defer { observer.cancel() }
        await session.start()
        helper.frame()
        try await eventually { states.last == .running(width: 2, height: 2) }
        helper.frame(width: 4, height: 2)
        try await eventually { states.last == .running(width: 4, height: 2) }
        await session.stop()
    }

    @Test func cancellingPendingTouchEndsRunAndReleasesHelper() async throws {
        let helper = FakeHelper()
        let session = IOSSimulatorSession(device: device, launch: { _ in helper }, requestTimeout: .seconds(5))
        await session.start()
        helper.frame()
        try await eventually { session.latestFrame() != nil }
        let request = Task { try await session.sendChecked(.touch(.down, .init(x: 0.5, y: 0.5), pointer: .ai)) }
        try await Task.sleep(for: .milliseconds(20))
        request.cancel()
        _ = await request.result
        try await eventually { session.activeSerial == nil }
        #expect(session.latestFrame() == nil)
    }

    @Test(arguments: [InputAction.key(.home), .text("must not be entered")])
    func alreadyCancelledCommandDoesNotWriteOrCloseHealthySession(_ action: InputAction) async throws {
        let helper = FakeHelper()
        let requests = RequestLog()
        helper.onRequest = { request in
            requests.append(request)
            helper.emit("{\"id\":\(request.id),\"ok\":true}")
        }
        let session = IOSSimulatorSession(device: device, launch: { _ in helper }, requestTimeout: .seconds(1))
        await session.start()
        helper.frame()
        try await eventually { session.latestFrame() != nil }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await session.sendChecked(action)
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(requests.snapshot.isEmpty)
        #expect(session.activeSerial == device.serial)
        #expect(session.latestFrame() != nil)
        await session.stop()
    }

    @Test func checkedInputPreservesPointerCoordinatesUnicodeAndClipboardAcknowledgements() async throws {
        let helper = FakeHelper()
        let requests = RequestLog()
        helper.onRequest = { request in
            requests.append(request)
            let text = request.command == "clipboard_get" ? ",\"text\":\"你好\"" : ""
            helper.emit("{\"id\":\(request.id),\"ok\":true\(text)}")
        }
        let session = IOSSimulatorSession(device: device, launch: { _ in helper }, requestTimeout: .seconds(1))
        await session.start()
        helper.frame()
        try await eventually { session.latestFrame() != nil }
        try await session.sendChecked(.touch(.down, .init(x: -1, y: 2), pointer: .ai))
        try await session.sendChecked(.touch(.up, .init(x: 0, y: 1), pointer: .ai))
        try await session.sendChecked(.key(.home))
        try await session.sendChecked(.text("中文 emoji 🐈"))
        try await session.setClipboard("粘贴", paste: true)
        #expect(try await session.getClipboard() == "你好")
        let sent = requests.snapshot
        #expect(sent.map(\.command) == ["touch", "touch", "key", "text", "clipboard_set", "clipboard_get"])
        #expect(sent.first?.pointer == "ai")
        #expect(sent.first?.x == 0)
        #expect(sent.first?.y == 1)
        #expect(sent[2].key == "home")
        #expect(sent[3].text == "中文 emoji 🐈")
        #expect(sent[4].text == "粘贴")
        #expect(sent[4].paste == true)
        await #expect(throws: DeviceError.self) { try await session.sendChecked(.key(.back)) }
        #expect(requests.snapshot.count == 6)
        await session.stop()
    }

    @Test func frameObserversCanBeRemovedWithoutAffectingOtherSubscribers() async throws {
        let helper = FakeHelper()
        let session = IOSSimulatorSession(device: device, launch: { _ in helper }, requestTimeout: .seconds(1))
        let first = FrameLog(), second = FrameLog()
        let token = session.addFrameObserver { first.append($0) }
        _ = session.addFrameObserver { second.append($0) }
        await session.start()
        helper.frame()
        try await eventually { first.count == 1 && second.count == 1 }
        session.removeFrameObserver(token)
        helper.frame(width: 4, height: 2)
        try await eventually { second.count == 2 }
        #expect(first.count == 1)
        await session.stop()
    }

    @Test func helperErrorPropagatesAndUnsupportedDoesNotEndRun() async throws {
        let helper = FakeHelper()
        let session = IOSSimulatorSession(device: device, launch: { _ in helper }, requestTimeout: .seconds(1))
        await session.start()
        helper.frame()
        try await eventually { session.latestFrame() != nil }
        helper.onRequest = { request in
            helper.emit("{\"id\":\(request.id),\"ok\":false,\"code\":\"UNSUPPORTED\",\"error\":\"native HID unavailable\"}")
        }
        do {
            try await session.sendChecked(.text("中文"))
            Issue.record("helper rejection was reported as success")
        } catch let error as DeviceError { #expect(error.code == .UNSUPPORTED) }
        #expect(session.activeSerial == device.serial)
        await session.stop()
    }

    @Test func timeoutEndsRunAndCompletesOtherPendingRequests() async throws {
        let helper = FakeHelper()
        let session = IOSSimulatorSession(device: device, launch: { _ in helper }, requestTimeout: .milliseconds(30))
        await session.start()
        helper.frame()
        try await eventually { session.latestFrame() != nil }
        await #expect(throws: DeviceError.self) { try await session.getClipboard() }
        #expect(session.activeSerial == nil)
        #expect(session.latestFrame() == nil)
    }

    @Test(arguments: [false, true])
    func queuedInputWaitsForNativePasteThenOrdinaryRequestsReturnToShortTimeout(_ paste: Bool) async throws {
        let helper = FakeHelper()
        let requests = RequestLog()
        helper.onRequest = { requests.append($0) }
        let session = IOSSimulatorSession(device: device, launch: { _ in helper },
                                          requestTimeout: .milliseconds(30), textRequestTimeout: .milliseconds(300))
        await session.start()
        helper.frame()
        try await eventually { session.latestFrame() != nil }
        let nativeInput = Task {
            if paste { try await session.setClipboard("native paste", paste: true) }
            else { try await session.sendChecked(.text("native text")) }
        }
        try await eventually { requests.snapshot.count == 1 }
        let queuedInput = Task {
            let action: InputAction = paste ? .touch(.down, .init(x: 0.5, y: 0.5)) : .key(.home)
            try await session.sendChecked(action)
        }
        try await eventually { requests.snapshot.count == 2 }
        // The helper is still executing the native paste; neither pending input may
        // consume the short ordinary-request budget while it waits behind that work.
        try await Task.sleep(for: .milliseconds(80))
        #expect(session.activeSerial == device.serial)
        for request in requests.snapshot {
            helper.emit("{\"id\":\(request.id),\"ok\":true}")
        }
        try await nativeInput.value
        try await queuedInput.value
        #expect(session.activeSerial == device.serial)

        let start = ContinuousClock.now
        await #expect(throws: DeviceError.self) { try await session.getClipboard() }
        #expect(start.duration(to: .now) < .milliseconds(150))
        #expect(session.activeSerial == nil)
        await session.stop()
    }

    @Test func blockedHelperWriteCannotBlockCommandTimeoutOrStop() async throws {
        let helper = FakeHelper()
        helper.stallWrites = true
        let session = IOSSimulatorSession(device: device, launch: { _ in helper }, requestTimeout: .milliseconds(30))
        await session.start()
        helper.frame()
        try await eventually { session.latestFrame() != nil }
        await #expect(throws: DeviceError.self) { try await session.setClipboard(String(repeating: "x", count: 100_000), paste: false) }
        #expect(session.activeSerial == nil)
        await session.stop()
    }

    @Test func restartWaitsForPreviousHelperToReleaseHID() async throws {
        let first = FakeHelper(), second = FakeHelper()
        first.exitDelay = .milliseconds(50)
        let factory = HelperSequence([first, second])
        let session = IOSSimulatorSession(device: device, launch: { _ in
            let next = factory.next()
            if next === second { #expect(first.didExit) }
            return next
        }, requestTimeout: .seconds(1))
        await session.start()
        first.frame()
        try await eventually { session.latestFrame() != nil }
        first.finish()
        try await eventually { session.activeSerial == nil }
        await session.start()
        #expect(first.didExit)
        await session.stop()
    }

    @Test func oldScrollCannotSendGestureTailIntoReconnectedHelper() async throws {
        let first = FakeHelper(), second = FakeHelper()
        let requests = RequestLog()
        let firstRequests = RequestLog()
        first.onRequest = { request in
            firstRequests.append(request)
            first.emit("{\"id\":\(request.id),\"ok\":true}")
        }
        second.onRequest = { request in
            requests.append(request)
            second.emit("{\"id\":\(request.id),\"ok\":true}")
        }
        let factory = HelperSequence([first, second])
        let session = IOSSimulatorSession(device: device, launch: { _ in factory.next() }, requestTimeout: .seconds(1))
        await session.start()
        first.frame()
        try await eventually { session.latestFrame() != nil }
        let gesture = Task { try await session.sendChecked(.scroll(.init(x: 0.5, y: 0.5), dx: 2, dy: 0)) }
        try await eventually { !firstRequests.snapshot.isEmpty }
        await session.stop()
        await session.start()
        second.frame()
        try await eventually { session.latestFrame() != nil }
        _ = await gesture.result
        #expect(requests.snapshot.isEmpty)
        #expect(session.activeSerial == device.serial)
        await session.stop()
    }

    @Test func reconnectRejectsOldGenerationAndUpdatesActiveSerialOnlyForNextRun() async throws {
        let first = FakeHelper(), second = FakeHelper()
        let factory = HelperSequence([first, second])
        let session = IOSSimulatorSession(device: device, launch: { _ in factory.next() }, requestTimeout: .seconds(1))
        await session.start()
        first.frame()
        try await eventually { session.latestFrame() != nil }
        var updated = device
        updated.serial = "B19835E8-C091-447D-BCC4-608B79D4F7C4"
        session.updateDevice(updated)
        #expect(session.activeSerial == device.serial)
        await session.stop()
        #expect(session.activeSerial == nil)
        await session.start()
        #expect(session.activeSerial == updated.serial)
        first.frame()
        #expect(session.latestFrame() == nil)
        second.frame()
        try await eventually { session.latestFrame() != nil }
        await session.stop()
        #expect(session.latestFrame() == nil)
    }

    @Test func scrollHasBoundedNormalizedSwipeAndAndroidHorizontalDirection() throws {
        let points = try SimulatorInput.scrollPoints(at: .init(x: 0.5, y: 0.5), dx: 1000, dy: -1000)
        #expect(points.first == .init(x: 0.5, y: 0.5))
        #expect(points.last == .init(x: 0.25, y: 0.25))
        #expect(throws: DeviceError.self) { try SimulatorInput.scrollPoints(at: .init(x: .nan, y: 0), dx: 0, dy: 0) }
    }
}

private func eventually(_ predicate: @escaping @Sendable () -> Bool) async throws {
    for _ in 0..<200 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    throw DeviceError.timeout("test condition")
}

private final class HelperSequence: @unchecked Sendable {
    let lock = NSLock()
    var helpers: [FakeHelper]
    init(_ helpers: [FakeHelper]) { self.helpers = helpers }
    func next() -> FakeHelper { lock.withLock { helpers.removeFirst() } }
}

private final class FakeHelper: SimulatorHelperProcess, @unchecked Sendable {
    let bytes: AsyncStream<Data>
    let output: AsyncStream<Data>.Continuation
    let lock = NSLock()
    var stallWrites = false
    var exitDelay: Duration = .zero
    private var exited = false
    var didExit: Bool { lock.withLock { exited } }
    private var handler: (@Sendable (SimulatorRequest) -> Void)?
    var onRequest: (@Sendable (SimulatorRequest) -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }
    init() { (bytes, output) = AsyncStream.makeStream() }
    func emit(_ line: String) { output.yield(Data((line + "\n").utf8)) }
    func frame(width: Int = 2, height: Int = 2) {
        // A real, decodable 2x2 JPEG tests the CVPixelBuffer path.
        let data = NSMutableData()
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        emit("{\"event\":\"frame\",\"jpeg\":\"\((data as Data).base64EncodedString())\",\"width\":\(width),\"height\":\(height)}")
    }
    func write(_ data: Data) async throws {
        if stallWrites { try await Task.sleep(for: .seconds(10)) }
        let request = try JSONDecoder().decode(SimulatorRequest.self, from: data)
        onRequest?(request)
    }
    func finish() { output.finish() }
    func terminate() { output.finish() }
    func waitUntilExit() async {
        try? await Task.sleep(for: exitDelay)
        lock.withLock { exited = true }
    }
}

@Suite struct SimulatorStdioTests {
    @Test func actualChildSeparatesStderrAndFlushesSplitStdoutBeforeEOF() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("helper")
        try Data("#!/bin/sh\nprintf '{\"event\":\"rea'\nprintf 'diagnostic only' >&2\nprintf 'dy\"}\\n'\nIFS= read -r request\nprintf '{\"id\":42,\"ok\":true}\\n'\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let helper = try StdioSimulatorHelper(url: script, udid: "3B76F05C-3449-4D26-A84F-BAB414513611")
        defer { helper.terminate() }
        try await helper.write(Data("{\"id\":42,\"command\":\"quit\"}\n".utf8))
        var decoder = SimulatorMessageDecoder()
        var messages: [SimulatorMessage] = []
        for await chunk in helper.bytes { messages += try decoder.append(chunk) }
        try decoder.finish()
        #expect(messages.count == 2)
        #expect(messages.first?.event == "ready")
        #expect(messages.last?.id == 42)
    }
}

private final class StateLog: @unchecked Sendable {
    let lock = NSLock()
    private var states: [SessionState] = []
    var last: SessionState? { lock.withLock { states.last } }
    func append(_ state: SessionState) { lock.withLock { states.append(state) } }
}

private final class RequestLog: @unchecked Sendable {
    let lock = NSLock()
    private var requests: [SimulatorRequest] = []
    var snapshot: [SimulatorRequest] { lock.withLock { requests } }
    func append(_ request: SimulatorRequest) { lock.withLock { requests.append(request) } }
}
private final class FrameLog: @unchecked Sendable {
    let lock = NSLock()
    private var frames: [VideoFrame] = []
    var count: Int { lock.withLock { frames.count } }
    func append(_ frame: VideoFrame) { lock.withLock { frames.append(frame) } }
}
