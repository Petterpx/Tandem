import CoreVideo
import DeviceCore
import Foundation
import Testing
@testable import IOSPhysicalDriver

@Suite struct USBSessionTests {
    let device = DeviceInfo(serial: "test-udid", platform: .ios, name: "iPhone USB", state: .connected, connection: .usb)
    @Test func replacementUsesOneTextRequestAndSharesGestureAndPendingAckExclusion() async throws {
        let helper = FakeUSBHelper()
        helper.acknowledge = true
        let session = IOSPhysicalSession(device: device, launch: { _ in helper }, requestTimeout: .seconds(1))
        await #expect(throws: DeviceError.self) { try await session.replaceText("替换🙂") }
        await session.start(); helper.frame()
        try await eventually { session.latestFrame() != nil }
        try await session.sendChecked(.touch(.down, .init(x: 0.5, y: 0.5), pointer: .finger))
        do {
            try await session.replaceText("替换🙂")
            Issue.record("Replacement interleaved with held gesture")
        } catch let error as DeviceError { #expect(error.code == .AI_LOCKED) }
        #expect(helper.requests.count == 1)
        try await session.sendChecked(.touch(.up, .init(x: 0.5, y: 0.5), pointer: .finger))
        helper.acknowledge = false
        let replacement = Task { try await session.replaceText("替换中文\n🙂") }
        try await eventually { helper.requests.count == 3 }
        let request = helper.requests[2]
        #expect(request["op"] as? String == "text")
        #expect(request["text"] as? String == "替换中文\n🙂")
        #expect(request["replace"] as? Bool == true)
        #expect(request["submit"] == nil)
        for action: InputAction in [.text("append"), .key(.enter), .touch(.down, .init(x: 0.5, y: 0.5), pointer: .finger)] {
            do {
                try await session.sendChecked(action)
                Issue.record("Input interleaved with pending replacement")
            } catch let error as DeviceError { #expect(error.code == .AI_LOCKED) }
        }
        await #expect(throws: DeviceError.self) { try await session.replaceText("second replacement") }
        let id = try #require(request["id"] as? Int)
        helper.emit("{\"event\":\"input_ack\",\"id\":\(id),\"sent\":true}")
        try await replacement.value
        #expect(helper.requests.count == 3)
        helper.acknowledge = true
        try await session.sendChecked(.text("append"))
        #expect(helper.requests[3]["replace"] == nil)
        await session.stop()
    }
    @Test func cancelledReplacementClosesSessionWithoutReplay() async throws {
        let helper = FakeUSBHelper()
        let session = IOSPhysicalSession(device: device, launch: { _ in helper }, requestTimeout: .seconds(1))
        await session.start(); helper.frame()
        try await eventually { session.latestFrame() != nil }
        let replacement = Task { try await session.replaceText("替换中文🙂") }
        try await eventually { helper.requests.count == 1 }
        replacement.cancel()
        await #expect(throws: CancellationError.self) { try await replacement.value }
        #expect(helper.requests.count == 1)
        #expect(helper.terminated)
        #expect(session.activeSerial == nil)
        await session.stop()
    }
    @Test func textRequiresCurrentRunningFrameAndCannotRestartStoppedSession() async throws {
        let helper = FakeUSBHelper()
        helper.acknowledge = true
        let session = IOSPhysicalSession(device: device, launch: { _ in helper }, requestTimeout: .seconds(1))
        await #expect(throws: DeviceError.self) { try await session.sendChecked(.text("中文")) }
        await session.start()
        await #expect(throws: DeviceError.self) { try await session.sendChecked(.text("中文")) }
        #expect(helper.requests.isEmpty)
        helper.frame()
        try await eventually { session.latestFrame() != nil }
        try await session.sendChecked(.text("中文"))
        #expect(helper.requests.count == 1)
        await session.stop()
        await #expect(throws: DeviceError.self) { try await session.sendChecked(.text("中文")) }
        #expect(helper.requests.count == 1)
        #expect(session.activeSerial == nil)
    }
    @Test func firstFrameGateObserverRotationAndEOF() async throws {
        let helper = FakeUSBHelper()
        let session = IOSPhysicalSession(device: device, launch: { _ in helper }, requestTimeout: .seconds(1))
        let frames = FrameCount()
        let token = session.addFrameObserver { _ in frames.increment() }
        await session.start()
        helper.emit(#"{"event":"ready"}"#)
        await #expect(throws: DeviceError.self) { try await session.sendChecked(.key(.home)) }
        helper.frame()
        try await eventually { session.latestFrame() != nil }
        #expect(frames.value == 1)
        session.removeFrameObserver(token)
        helper.frame(width: 4)
        try await eventually { session.latestFrame().map { CVPixelBufferGetWidth($0.pixelBuffer) } == 4 }
        #expect(frames.value == 1)
        helper.finish()
        try await eventually { session.activeSerial == nil }
        #expect(session.latestFrame() == nil)
        await session.stop()
    }
    @Test func checkedInputAckFailureAndOwnership() async throws {
        let helper = FakeUSBHelper()
        helper.acknowledge = true
        let session = IOSPhysicalSession(device: device, launch: { _ in helper }, requestTimeout: .seconds(1))
        await session.start(); helper.frame()
        try await eventually { session.latestFrame() != nil }
        try await session.sendChecked(.touch(.down, .init(x: -1, y: 2), pointer: .ai))
        await #expect(throws: DeviceError.self) { try await session.sendChecked(.touch(.up, .init(x: 0, y: 0), pointer: .finger)) }
        #expect(helper.requests.count == 1)
        try await session.sendChecked(.touch(.move, .init(x: 0.5, y: 0.5), pointer: .ai))
        try await session.sendChecked(.touch(.up, .init(x: 0.5, y: 0.5), pointer: .ai))
        try await session.sendChecked(.key(.home))
        await #expect(throws: DeviceError.self) { try await session.sendChecked(.key(.forwardDelete)) }
        await #expect(throws: DeviceError.self) { try await session.setClipboard("private", paste: true) }
        #expect(helper.requests.count == 4)
        #expect(helper.requests[0]["x"] as? Double == 0)
        #expect(helper.requests[0]["y"] as? Double == 1)
        helper.reject = true
        await #expect(throws: DeviceError.self) { try await session.sendChecked(.key(.home)) }
        await session.stop()
    }
    @Test func unicodeTextAndSupportedKeysAreAcknowledgedWithoutAutomaticSubmit() async throws {
        let helper = FakeUSBHelper()
        helper.acknowledge = true
        let session = IOSPhysicalSession(device: device, launch: { _ in helper }, requestTimeout: .seconds(1))
        await session.start(); helper.frame()
        try await eventually { session.latestFrame() != nil }
        let text = "ASCII 中文\n🙂👩🏽‍💻"
        try await session.sendChecked(.text(text))
        #expect(helper.requests.count == 1)
        #expect(helper.requests[0]["op"] as? String == "text")
        #expect(helper.requests[0]["text"] as? String == text)
        #expect(helper.requests[0]["submit"] == nil)
        for key: DeviceKey in [.enter, .delete, .tab, .up, .down, .left, .right] {
            try await session.sendChecked(.key(key))
        }
        #expect(helper.requests.dropFirst().compactMap { $0["key"] as? String } == ["enter", "delete", "tab", "up", "down", "left", "right"])
        await session.stop()
    }
    @Test func textRejectsHeldTouchAndInvalidPayloadBeforeWriting() async throws {
        let helper = FakeUSBHelper()
        helper.acknowledge = true
        let session = IOSPhysicalSession(device: device, launch: { _ in helper }, requestTimeout: .seconds(1))
        await session.start(); helper.frame()
        try await eventually { session.latestFrame() != nil }
        try await session.sendChecked(.touch(.down, .init(x: 0.5, y: 0.5), pointer: .finger))
        do {
            try await session.sendChecked(.text("中文"))
            Issue.record("Text inserted during held gesture")
        } catch let error as DeviceError { #expect(error.code == .AI_LOCKED) }
        #expect(helper.requests.count == 1)
        try await session.sendChecked(.touch(.up, .init(x: 0.5, y: 0.5), pointer: .finger))
        for invalid in ["", "\0", String(repeating: "a", count: 8193), String(repeating: "\n", count: 8192)] {
            await #expect(throws: DeviceError.self) { try await session.sendChecked(.text(invalid)) }
        }
        #expect(helper.requests.count == 2)
        #expect(session.activeSerial != nil)
        await session.stop()
    }
    @Test func pendingTextExcludesTouchAndTimeoutNeverReplays() async throws {
        let helper = FakeUSBHelper()
        let session = IOSPhysicalSession(device: device, launch: { _ in helper }, requestTimeout: .milliseconds(150))
        await session.start(); helper.frame()
        try await eventually { session.latestFrame() != nil }
        let text = Task { try await session.sendChecked(.text("中文🙂")) }
        try await eventually { helper.requests.count == 1 }
        do {
            try await session.sendChecked(.touch(.down, .init(x: 0.5, y: 0.5), pointer: .finger))
            Issue.record("Touch interleaved with text insertion")
        } catch let error as DeviceError { #expect(error.code == .AI_LOCKED) }
        await #expect(throws: DeviceError.self) { try await text.value }
        #expect(helper.requests.count == 1)
        #expect(helper.terminated)
        #expect(session.activeSerial == nil)
        await #expect(throws: DeviceError.self) { try await session.sendChecked(.text("中文🙂")) }
        #expect(helper.requests.count == 1)
        await session.stop()
    }
    @Test func textRejectionAndCancellationTearDownWithoutReplay() async throws {
        for cancelled in [false, true] {
            let helper = FakeUSBHelper()
            helper.acknowledge = !cancelled
            helper.reject = !cancelled
            let session = IOSPhysicalSession(device: device, launch: { _ in helper }, requestTimeout: .seconds(1))
            await session.start(); helper.frame()
            try await eventually { session.latestFrame() != nil }
            let text = Task { try await session.sendChecked(.text("sensitive text")) }
            try await eventually { helper.requests.count == 1 }
            if cancelled { text.cancel() }
            switch await text.result {
            case .success: Issue.record("Rejected or cancelled text reported success")
            case .failure: break
            }
            #expect(helper.requests.count == 1)
            #expect(helper.terminated)
            #expect(session.activeSerial == nil)
            await session.stop()
        }
    }
    @Test func missingNativeTextServiceReturnsUnsupportedAndClosesSession() async throws {
        let helper = FakeUSBHelper()
        let session = IOSPhysicalSession(device: device, launch: { _ in helper }, requestTimeout: .seconds(1))
        await session.start(); helper.frame()
        try await eventually { session.latestFrame() != nil }
        let text = Task { try await session.sendChecked(.text("private payload")) }
        try await eventually { helper.requests.count == 1 }
        let requestID = try #require(helper.requests[0]["id"] as? Int)
        helper.emit("{\"event\":\"input_ack\",\"id\":\(requestID),\"sent\":false,\"error\":\"native pasteboard service unavailable\"}")
        do {
            try await text.value
            Issue.record("Unavailable text service reported success")
        } catch let error as DeviceError {
            #expect(error.code == .UNSUPPORTED)
            #expect(!error.message.contains("private payload"))
        }
        #expect(helper.requests.count == 1)
        #expect(helper.terminated)
        #expect(session.activeSerial == nil)
        await session.stop()
    }
    @Test func timeoutNeverReplaysAndStopWaitsForExit() async throws {
        let helper = FakeUSBHelper()
        helper.holdExit = true
        let session = IOSPhysicalSession(device: device, launch: { _ in helper }, requestTimeout: .milliseconds(30))
        await session.start(); helper.frame()
        try await eventually { session.latestFrame() != nil }
        await #expect(throws: DeviceError.self) { try await session.sendChecked(.touch(.down, .init(x: 0.5, y: 0.5), pointer: .ai)) }
        #expect(helper.requests.count == 1)
        #expect(helper.terminated)
        #expect(session.latestFrame() == nil)
        let stopped = FrameCount()
        let stop = Task { await session.stop(); stopped.increment() }
        try await Task.sleep(for: .milliseconds(40))
        #expect(stopped.value == 0)
        helper.releaseExit()
        await stop.value
        #expect(stopped.value == 1)
    }
    @Test func cancellationCleansOwnedTouchAndOldFramesCannotCrossRestart() async throws {
        let old = FakeUSBHelper(), new = FakeUSBHelper()
        let factory = HelperFactory([old, new])
        let session = IOSPhysicalSession(device: device, launch: { _ in factory.next() }, requestTimeout: .seconds(2))
        await session.start(); old.frame()
        try await eventually { session.latestFrame() != nil }
        let request = Task { try await session.sendChecked(.touch(.down, .init(x: 0.5, y: 0.5), pointer: .ai)) }
        try await eventually { old.requests.count == 1 }
        request.cancel()
        _ = await request.result
        #expect(old.terminated)
        await session.start()
        old.frame(width: 7)
        new.frame(width: 4)
        try await eventually { session.latestFrame().map { CVPixelBufferGetWidth($0.pixelBuffer) } == 4 }
        new.acknowledge = true
        try await session.sendChecked(.touch(.down, .init(x: 0.5, y: 0.5), pointer: .finger))
        try await session.sendChecked(.touch(.up, .init(x: 0.5, y: 0.5), pointer: .finger))
        await session.stop()
    }
    @Test func sameSourceUpQueuesBehindDownWhileForeignSourceCannotRelease() async throws {
        let helper = FakeUSBHelper()
        let session = IOSPhysicalSession(device: device, launch: { _ in helper }, requestTimeout: .seconds(2))
        await session.start(); helper.frame()
        try await eventually { session.latestFrame() != nil }
        let down = Task { try await session.sendChecked(.touch(.down, .init(x: 0.5, y: 0.5), pointer: .ai)) }
        try await eventually { helper.requests.count == 1 }
        helper.emit(#"{"event":"input_ack","id":99999,"sent":true}"#)
        await #expect(throws: DeviceError.self) { try await session.sendChecked(.touch(.up, .init(x: 0.5, y: 0.5), pointer: .finger)) }
        let up = Task { try await session.sendChecked(.touch(.up, .init(x: 0.5, y: 0.5), pointer: .ai)) }
        try await Task.sleep(for: .milliseconds(20))
        #expect(helper.requests.count == 1)
        let downID = try #require(helper.requests[0]["id"] as? Int)
        helper.emit("{\"event\":\"input_ack\",\"id\":\(downID),\"sent\":true}")
        try await down.value
        try await eventually { helper.requests.count == 2 }
        let upID = try #require(helper.requests[1]["id"] as? Int)
        helper.emit("{\"event\":\"input_ack\",\"id\":\(upID),\"sent\":true}")
        try await up.value
        #expect(session.activeSerial != nil)
        #expect(helper.requests.map { $0["phase"] as? String } == ["down", "up"])
        await session.stop()
    }
    @Test func cachedSessionAllowsEventSubscriptionAfterPreviousConsumerCancelled() async throws {
        let first = FakeUSBHelper(), second = FakeUSBHelper()
        let factory = HelperFactory([first, second])
        let session = IOSPhysicalSession(device: device, launch: { _ in factory.next() }, requestTimeout: .seconds(1))
        let firstEvents = FrameCount()
        let stream = session.events
        let consumer = Task { for await _ in stream { firstEvents.increment() } }
        await session.start()
        try await eventually { firstEvents.value >= 1 }
        consumer.cancel()
        await consumer.value
        await session.stop()
        let secondEvents = FrameCount()
        let replacement = session.events
        let nextConsumer = Task { for await _ in replacement { secondEvents.increment() } }
        defer { nextConsumer.cancel() }
        await session.start()
        second.frame()
        try await eventually { secondEvents.value >= 3 && session.latestFrame() != nil }
        #expect(session.latestFrame() != nil)
        await session.stop()
    }
    @Test func subscribingToAlreadyRunningSessionReplaysRunningState() async throws {
        let helper = FakeUSBHelper()
        let session = IOSPhysicalSession(device: device, launch: { _ in helper }, requestTimeout: .seconds(1))
        await session.start(); helper.frame(width: 4)
        try await eventually { session.latestFrame() != nil }
        await session.start() // Actor barrier: first-frame state publication has completed.
        var iterator = session.events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event == .state(.running(width: 4, height: 2)))
        await session.stop()
    }
    @Test func driverSharesSessionForSameUDID() {
        let driver = IOSPhysicalDriver()
        #expect(driver.makeSession(for: device) === driver.makeSession(for: device))
    }
}

final class FrameCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
final class HelperFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var helpers: [FakeUSBHelper]
    init(_ helpers: [FakeUSBHelper]) { self.helpers = helpers }
    func next() -> FakeUSBHelper { lock.withLock { helpers.removeFirst() } }
}
final class FakeUSBHelper: USBHelperProcess, @unchecked Sendable {
    let bytes: AsyncStream<Data>
    let frames: AsyncThrowingStream<VideoFrame, any Error>
    private let output: AsyncStream<Data>.Continuation
    private let video: AsyncThrowingStream<VideoFrame, any Error>.Continuation
    private let lock = NSLock()
    private var recorded: [Data] = []
    private var ended = false
    private var exited = false
    private var ack = false
    private var rejected = false
    private var held = false
    var acknowledge: Bool { get { lock.withLock { ack } } set { lock.withLock { ack = newValue } } }
    var reject: Bool { get { lock.withLock { rejected } } set { lock.withLock { rejected = newValue } } }
    var holdExit: Bool { get { lock.withLock { held } } set { lock.withLock { held = newValue } } }
    var terminated: Bool { lock.withLock { ended } }
    var requests: [[String: Any]] { lock.withLock { recorded.map { try! JSONSerialization.jsonObject(with: $0) as! [String: Any] } } }
    init() {
        (bytes, output) = AsyncStream.makeStream()
        (frames, video) = AsyncThrowingStream.makeStream()
    }
    func emit(_ text: String) { output.yield(Data((text + "\n").utf8)) }
    func frame(width: Int = 2) {
        var pixel: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, 2, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
        if let pixel { video.yield(.init(pixelBuffer: pixel)) }
    }
    func write(_ data: Data) async throws {
        lock.withLock { recorded.append(data) }
        if acknowledge {
            let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let id = object["id"] as! Int
            emit("{\"event\":\"input_ack\",\"id\":\(id),\"sent\":\(!reject)}")
        }
    }
    func finish() { output.finish(); video.finish() }
    func terminate() { lock.withLock { ended = true; if !held { exited = true } } }
    func releaseExit() { lock.withLock { exited = true } }
    func waitUntilExit() async { while !lock.withLock({ exited }) { try? await Task.sleep(for: .milliseconds(5)) } }
}
func eventually(_ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<200 { if condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
    throw DeviceError.timeout("测试条件")
}
