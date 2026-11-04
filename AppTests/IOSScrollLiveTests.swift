import AppKit
import CoreVideo
import DeviceCore
import Foundation
import IOSSimulatorDriver
import Testing
@testable import Tandem

/// Explicit opt-in; use only a disposable simulator running ScrollFixture.
/// Events go directly to this test's hidden view and are never posted to macOS.
@MainActor
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TANDEM_SCROLL_BENCHMARK"] == "1"
    && ProcessInfo.processInfo.environment["TANDEM_TEST_SIMULATOR"] != nil
    && ProcessInfo.processInfo.environment["TANDEM_SIMULATOR_HELPER"] != nil))
struct IOSScrollLiveTests {
    @Test(.timeLimit(.minutes(2)))
    func realViewScrollStopsWithoutBacklogOrHeldNativeTouch() async throws {
        let environment = ProcessInfo.processInfo.environment
        let udid = try #require(environment["TANDEM_TEST_SIMULATOR"])
        let helper = try #require(environment["TANDEM_SIMULATOR_HELPER"])
        let bundle = "local.tandem.scroll-fixture"
        let fixtureLaunch = ProcessInfo.processInfo.systemUptime
        _ = try simctl(["launch", "--terminate-running-process", udid, bundle])
        let container = try simctl(["get_app_container", udid, bundle, "data"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let stateURL = URL(fileURLWithPath: container).appendingPathComponent("Documents/scroll-state.json")
        let session = IOSSimulatorSession(device: DeviceInfo(serial: udid, platform: .ios,
            name: "Scroll integration", state: .connected, connection: .simulator),
            helperURL: URL(fileURLWithPath: helper))
        let log = ScrollLiveLog()
        let motion = ScrollLiveMotionLog()
        let frameObserver = session.addFrameObserver { motion.frame($0) }
        let events = Task {
            for await event in session.events {
                if case let .state(.failed(error)) = event { log.failure("session: \(error)") }
            }
        }
        await session.start()
        let router = InputRouter()
        var consumer: Task<Void, Never>?
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 844),
            styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let view = VideoSurfaceView(frame: NSRect(x: 0, y: 0, width: 390, height: 844))
        view.platform = .ios
        view.sizesWindow = false
        window.contentView = NSView(frame: view.bounds)
        window.contentView?.addSubview(view)
        view.onInput = { motion.source($0); router.yield(.action($0)) }
        func startConsumer() -> Task<Void, Never> {
            Task {
                await router.run(coalescing: true) { operation in
                    guard case let .action(action) = operation else { return }
                    let started = ProcessInfo.processInfo.systemUptime
                    do {
                        try await session.sendChecked(action)
                        log.completed(action, started: started)
                    } catch { log.failure("\(action): \(error)") }
                }
            }
        }
        do {
            try await wait("decoded simulator frame", seconds: 25) { session.latestFrame() != nil }
            let frame = try #require(session.latestFrame())
            view.show(frame)
            // Match the decoded aspect ratio: synthetic points follow the same conversion as the UI.
            view.frame.size = CGSize(width: 390,
                height: 390 * CGFloat(CVPixelBufferGetHeight(frame.pixelBuffer)) / CGFloat(CVPixelBufferGetWidth(frame.pixelBuffer)))
            window.contentView?.frame.size = view.frame.size
            _ = window.makeFirstResponder(view)
            try await wait("fresh ScrollFixture state", seconds: 10) {
                readState(stateURL)?.events.contains(where: { $0.kind == "ready" && $0.uptime >= fixtureLaunch }) == true
            }
            consumer = startConsumer()
            try await Task.sleep(for: .milliseconds(30))
            var measurements: [[String: Any]] = []
            var sampleCursor = 0

            func wheel(_ phase: NSEvent.Phase = [], momentum: NSEvent.Phase = [], dy: CGFloat = -2) {
                let event = ScrollLiveEvent(location: view.convert(
                    CGPoint(x: view.bounds.width * 0.5, y: view.bounds.height * 0.78), to: nil),
                    dy: dy, phase: phase, momentum: momentum)
                motion.wheel(dy: Double(dy), phase: phase, momentum: momentum, timestamp: event.timestamp)
                view.scrollWheel(with: event)
            }
            func pace(_ count: Int, hz: Double, event: (Int) -> Void) async throws {
                let start = ContinuousClock.now
                for index in 0..<count {
                    try await ContinuousClock().sleep(until: start + .nanoseconds(Int64(Double(index) / hz * 1e9)))
                    event(index)
                }
            }
            func barrier(_ name: String, budget: Double = 300) async throws {
                let stopped = ProcessInfo.processInfo.systemUptime
                let before = log.keyCount
                let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                    modifierFlags: [], timestamp: stopped, windowNumber: window.windowNumber,
                    context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                    isARepeat: false, keyCode: 36))
                view.keyDown(with: event)
                try await wait("\(name): key after source stop", seconds: 12) { log.keyCount > before }
                let drain = (ProcessInfo.processInfo.systemUptime - stopped) * 1000
                let samples = log.samples
                let scrolls = samples.dropFirst(sampleCursor).filter { $0.isScroll }
                sampleCursor = samples.count
                measurements.append(["scenario": name, "post_source_stop_key_ms": drain,
                    "scroll_operations": scrolls.count,
                    "scroll_completed_after_source_stop": scrolls.filter { $0.finished > stopped }.count,
                    "scroll_durations_ms": scrolls.map { ($0.finished - $0.started) * 1000 },
                    "scroll_finish_relative_to_source_stop_ms": scrolls.map { ($0.finished - stopped) * 1000 }])
                #expect(drain < budget, "\(name): stale scroll work delayed the next key by \(drain) ms")
                let expectedContacts = log.touchDownCount + log.scrollCount
                // File publication can lag its captured UIKit events under host
                // pressure. Wait for evidence independently of the event-time budget.
                try await wait("\(name): published native release", seconds: 10) {
                    guard let state = readState(stateURL) else { return false }
                    return state.endedTouchCount >= expectedContacts && state.hasReleasedTouch
                }
                let state = try #require(readState(stateURL))
                let nativeEnd = try #require(state.endedTouches.dropFirst(expectedContacts - 1).first)
                let nativeRelease = max(0, nativeEnd.uptime - stopped) * 1000
                measurements.append(["scenario": "\(name)-UIKit-release", "post_source_stop_ms": nativeRelease])
                #expect(nativeRelease < budget, "\(name): UIKit kept receiving stale motion after source stop for \(nativeRelease) ms")
            }
            func clickAfterScroll(_ name: String) async throws {
                let before = try #require(readState(stateURL))
                let point = view.convert(CGPoint(x: view.bounds.width * before.buttonX,
                    y: view.bounds.height * before.buttonY), to: nil)
                let started = ProcessInfo.processInfo.systemUptime
                for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                    let event = try #require(NSEvent.mouseEvent(with: type, location: point,
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                        clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0))
                    if type == .leftMouseDown { view.mouseDown(with: event) }
                    else { view.mouseUp(with: event) }
                }
                try await wait("\(name): next click reaches UIKit", seconds: 3) {
                    (readState(stateURL)?.buttonTaps ?? 0) > before.buttonTaps
                }
                let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
                measurements.append(["scenario": "\(name)-click", "completion_ms": milliseconds])
                #expect(milliseconds < 1_000, "\(name): click remained blocked after scrolling")
            }

            // UIKit's first table scroll after launch can spend ~1.7 s building cold rendering state.
            // Report that setup separately; benchmark the same, already rendered fixture process.
            let coldStart = ProcessInfo.processInfo.systemUptime
            let coldInitialOffset = readState(stateURL)?.offset ?? 0
            wheel(.began, dy: 0)
            try await pace(36, hz: 120) { _ in wheel(.changed) }
            let coldStopped = ProcessInfo.processInfo.systemUptime
            wheel(.ended, dy: 0)
            try await barrier("cold-fixture-warmup", budget: 3_000)
            if environment["TANDEM_SCROLL_FOLLOW"] == "1", let state = readState(stateURL) {
                let report = try motion.report(name: "follow-cold-fixture", start: coldStart,
                    stopped: coldStopped, released: ProcessInfo.processInfo.systemUptime,
                    initialOffset: coldInitialOffset, state: state, reverse: false, hold: false)
                let summary = report.filter { !["source_wheels", "source_touch_actions"].contains($0.key) }
                measurements.append(summary)
                let data = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
                print("TANDEM_SCROLL_FOLLOW \(String(decoding: data, as: UTF8.self))")
            }
            try await clickAfterScroll("cold-fixture-warmup")
            try await Task.sleep(for: .seconds(2))

            if environment["TANDEM_SCROLL_FOLLOW"] == "1" {
                // These observations catch a different failure from the stop barrier below:
                // a finger can eventually release correctly while its page stayed frozen
                // for the first half of the gesture, or while later motion hit a screen edge.
                func follow(_ name: String, count: Int, dy: CGFloat,
                            reverse: Bool = false, hold: Bool = false) async throws {
                    try await wait("\(name): prior native deceleration", seconds: 10) {
                        readState(stateURL)?.decelerating == false
                    }
                    let start = ProcessInfo.processInfo.systemUptime
                    let startState = try #require(readState(stateURL))
                    wheel(.began, dy: 0)
                    try await pace(count, hz: 120) { index in
                        wheel(.changed, dy: reverse && index >= count / 2 ? -dy : dy)
                    }
                    let stopped = ProcessInfo.processInfo.systemUptime
                    if hold { try await Task.sleep(for: .milliseconds(300)) }
                    let released = ProcessInfo.processInfo.systemUptime
                    wheel(.ended, dy: 0)
                    try await barrier(name)
                    // Read evidence after publication catches up; all latency calculations
                    // use guest event uptime, never state-file arrival time.
                    try await wait("\(name): published native evidence", seconds: 10) {
                        (readState(stateURL)?.uptime ?? 0) > released + 0.15
                    }
                    let state = try #require(readState(stateURL))
                    let report = try motion.report(name: name, start: start, stopped: stopped,
                        released: released, initialOffset: startState.offset,
                        state: state, reverse: reverse, hold: hold)
                    let summary = report.filter { !["source_wheels", "source_touch_actions"].contains($0.key) }
                    measurements.append(summary)
                    let reportData = try JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys])
                    print("TANDEM_SCROLL_FOLLOW \(String(decoding: reportData, as: UTF8.self))")
                    if environment["TANDEM_SCROLL_FOLLOW_REPORT_ONLY"] != "1" {
                        let firstMotion = try #require(report["first_UIKit_offset_ms"] as? Double)
                        #expect(firstMotion < 100, "\(name): page did not follow the first finger movement: \(firstMotion) ms")
                        let quarters = try #require(report["quarters"] as? [[String: Any]])
                        for quarter in quarters {
                            let movement = try #require(quarter["UIKit_offset_range_pt"] as? Double)
                            #expect(movement > 5, "\(name): no useful page progress in quarter \(quarter)")
                        }
                        if reverse {
                            let reversal = try #require(report["UIKit_reversal_ms"] as? Double)
                            #expect(reversal < 100, "\(name): reversal lagged by \(reversal) ms")
                        }
                        if hold {
                            let drift = try #require(report["held_pause_UIKit_drift_pt"] as? Double)
                            #expect(drift < 2, "\(name): page continued moving while finger was stationary: \(drift) pt")
                            #expect(report["held_pause_native_releases"] as? Int == 0,
                                "A pause with fingers down must retain its native contact")
                            #expect(report["held_pause_native_moves_after_100ms"] as? Int == 0,
                                "No stale native motion may replay throughout the held pause")
                        }
                    }
                    if let directory = environment["TANDEM_SCROLL_TRACE_DIRECTORY"] {
                        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
                        try Data(contentsOf: stateURL).write(to: URL(fileURLWithPath: directory)
                            .appendingPathComponent("\(name)-guest.json"), options: .atomic)
                        try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
                            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-host.json"), options: .atomic)
                    }
                }
                try await follow("follow-sustained", count: 120, dy: -2)
                try await follow("follow-quick-reversal", count: 120, dy: -2, reverse: true)
                try await follow("follow-held-pause", count: 72, dy: -2, hold: true)
                try await follow("follow-long-slide-edge", count: 240, dy: -8)
                if environment["TANDEM_SCROLL_FOLLOW_ONLY"] == "1" {
                    #expect(log.failures.isEmpty, "Native errors: \(log.failures)")
                    consumer?.cancel()
                    await consumer?.value
                    view.onInput = nil
                    window.close()
                    await session.stop()
                    session.removeFrameObserver(frameObserver)
                    events.cancel()
                    return
                }
            }

            // Removing move coalescing makes native display RPCs queue all 120 Hz samples.
            let initial = try #require(readState(stateURL))
            wheel(.began, dy: 0)
            try await pace(72, hz: 120) { _ in wheel(.changed) }
            wheel(.ended, dy: 0)
            try await barrier("phased-120Hz")
            let scrolled = try #require(readState(stateURL))
            #expect(scrolled.panCount > initial.panCount, "Real UIKit must observe the continuous drag")
            #expect(abs(scrolled.offset - initial.offset) > 10, "The table must actually scroll")
            try await clickAfterScroll("phased-120Hz")

            // Up/down boundaries must survive while several gestures are produced faster than ACKs.
            for _ in 0..<10 {
                wheel(.began, dy: 0)
                try await pace(6, hz: 120) { _ in wheel(.changed, dy: -3) }
                wheel(.ended, dy: 0)
            }
            try await barrier("rapid-ten-gestures")
            try await clickAfterScroll("rapid-ten-gestures")

            // Without wheel coalescing this is >=8 seconds of synthetic swipe replay.
            try await pace(60, hz: 60) { _ in wheel(dy: -1) }
            try await barrier("unphased-wheel-60Hz")
            try await clickAfterScroll("unphased-wheel-60Hz")

            // No key, click or lifecycle event may be needed to release a precise
            // phase-less gesture: stopping the source must let the idle timer lift it.
            let idleContact = log.touchDownCount + log.scrollCount + 1
            try await pace(36, hz: 60) { _ in wheel(dy: -2) }
            let idleSourceStopped = ProcessInfo.processInfo.systemUptime
            try await wait("published phase-less native release without another input", seconds: 10) {
                guard let state = readState(stateURL) else { return false }
                return state.endedTouchCount >= idleContact && state.hasReleasedTouch
            }
            let idleState = try #require(readState(stateURL))
            let idleEnd = try #require(idleState.endedTouches.dropFirst(idleContact - 1).first)
            let idleRelease = max(0, idleEnd.uptime - idleSourceStopped) * 1000
            measurements.append(["scenario": "unphased-idle-without-next-input", "native_release_ms": idleRelease])
            #expect(idleRelease < 300, "Stopping phase-less input must release its native finger without a key")
            #expect(log.touchDownCount + log.scrollCount == idleContact,
                "One continuous phase-less source must produce one native contact")
            try await clickAfterScroll("unphased-idle-without-next-input")

            let contactsBeforeMomentumGesture = try #require(readState(stateURL)).endedTouchCount
            wheel(.began, dy: 0)
            try await pace(24, hz: 120) { _ in wheel(.changed) }
            wheel(.ended, dy: 0)
            try await pace(30, hz: 120) { index in
                wheel(momentum: index == 0 ? .began : .changed, dy: -20)
            }
            wheel(momentum: .ended, dy: 0)
            try await barrier("ended-plus-momentum")
            let afterMomentum = try #require(readState(stateURL))
            #expect(afterMomentum.endedTouchCount == contactsBeforeMomentumGesture + 1,
                "The gesture plus momentum must produce exactly one native finger contact")

            // A phase-less momentum transition must release a gesture even without phase.ended.
            wheel(.began, dy: 0)
            try await pace(12, hz: 120) { _ in wheel(.changed) }
            wheel(momentum: .began, dy: -20)
            try await barrier("momentum-without-ended")

            wheel(.began, dy: 0)
            try await pace(12, hz: 120) { _ in wheel(.changed) }
            wheel(.cancelled, dy: 0)
            try await barrier("phase-cancelled")

            for detach in [false, true] {
                _ = window.makeFirstResponder(view)
                wheel(.began, dy: 0)
                try await pace(12, hz: 120) { _ in wheel(.changed) }
                if detach { view.removeFromSuperview() }
                else { _ = window.makeFirstResponder(window.contentView) }
                try await barrier(detach ? "view-detached" : "focus-lost")
                if detach { window.contentView?.addSubview(view) }
            }

            // Cancelling an idle router while its native touch is held must still send the release.
            _ = window.makeFirstResponder(view)
            let movesBeforeCancellationGesture = log.moveCount
            wheel(.began, dy: 0)
            try await pace(12, hz: 120) { _ in wheel(.changed) }
            let lastPoint = NormalizedPoint(x: 0.5, y: 0.78 - 24 / Double(view.bounds.height))
            try await wait("native move before router cancellation", seconds: 3) {
                guard let move = log.lastMove else { return false }
                return log.moveCount > movesBeforeCancellationGesture
                    && abs(move.x - lastPoint.x) < 0.000_001 && abs(move.y - lastPoint.y) < 0.000_001
                    && readState(stateURL)?.touchBalance == 1
            }
            let cancelledAt = ProcessInfo.processInfo.systemUptime
            consumer?.cancel()
            await consumer?.value
            try await wait("published native release after router cancellation", seconds: 10) {
                guard let state = readState(stateURL) else { return false }
                return state.hasReleasedTouch
            }
            let released = try #require(readState(stateURL))
            let cancellation = max(0, try #require(released.endedTouches.last).uptime - cancelledAt) * 1000
            measurements.append(["scenario": "router-cancel", "native_release_ms": cancellation])
            #expect(cancellation < 1_000)
            consumer = startConsumer()
            try await Task.sleep(for: .milliseconds(30))
            // Drop the view's stale local gesture after the router has released it.
            view.onInput = nil
            _ = window.makeFirstResponder(window.contentView)
            view.onInput = { router.yield(.action($0)) }
            try await clickAfterScroll("router-cancel")
            #expect(log.failures.isEmpty, "Every native input error is retained: \(log.failures)")
            let data = try JSONSerialization.data(withJSONObject: measurements, options: [.sortedKeys])
            print("TANDEM_SCROLL_BENCHMARK \(String(decoding: data, as: UTF8.self))")
            consumer?.cancel()
            await consumer?.value
            view.onInput = nil
            window.close()
            await session.stop()
            session.removeFrameObserver(frameObserver)
            events.cancel()
        } catch {
            consumer?.cancel()
            await consumer?.value
            view.onInput = nil
            window.close()
            await session.stop()
            session.removeFrameObserver(frameObserver)
            events.cancel()
            Issue.record("Native input errors before failure: \(log.failures)")
            throw error
        }
    }

    private func wait(_ description: String, seconds: Double, until predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !predicate() {
            if ProcessInfo.processInfo.systemUptime >= deadline {
                throw ScrollLiveFailure(message: "Timed out: \(description)")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func simctl(_ arguments: [String]) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl"] + arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw ScrollLiveFailure(message: "simctl \(arguments): \(text)") }
        return text
    }

    private func readState(_ url: URL) -> ScrollLiveState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ScrollLiveState.self, from: data)
    }
}

private struct ScrollLiveFailure: Error { let message: String }

private struct ScrollLiveState: Decodable {
    struct Event: Decodable {
        let kind: String; let phase: String?; let uptime: Double
        let eventTimestamp: Double?; let x: Double?; let y: Double?
        let offset: Double?; let decelerating: Bool?
    }
    let uptime: Double?
    let decelerating: Bool?
    let events: [Event]
    let buttonTaps: Int
    let offset: Double
    let dragging: Bool
    let panState: Int
    let buttonX: Double
    let buttonY: Double
    var panCount: Int { events.filter { $0.kind == "pan" }.count }
    // UIKit's drag/pan properties may remain active during native deceleration.
    // Actual touch delivery is the authority for whether a finger remains held.
    var hasReleasedTouch: Bool { touchBalance == 0 }
    var endedTouches: [Event] { events.filter { $0.kind == "touch" && ["ended", "cancelled"].contains($0.phase ?? "") } }
    var endedTouchCount: Int { endedTouches.count }
    var touchBalance: Int {
        events.reduce(0) { count, event in
            guard event.kind == "touch" else { return count }
            return count + (event.phase == "began" ? 1 : ["ended", "cancelled"].contains(event.phase) ? -1 : 0)
        }
    }
}

private final class ScrollLiveEvent: NSEvent, @unchecked Sendable {
    private let location: CGPoint
    private let delta: CGFloat
    private let sourcePhase: NSEvent.Phase
    private let inertiaPhase: NSEvent.Phase
    private let sentTime = ProcessInfo.processInfo.systemUptime
    init(location: CGPoint, dy: CGFloat, phase: NSEvent.Phase, momentum: NSEvent.Phase) {
        self.location = location
        delta = dy
        sourcePhase = phase
        inertiaPhase = momentum
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override var locationInWindow: NSPoint { location }
    override var scrollingDeltaX: CGFloat { 0 }
    override var scrollingDeltaY: CGFloat { delta }
    override var hasPreciseScrollingDeltas: Bool { true }
    override var phase: NSEvent.Phase { sourcePhase }
    override var momentumPhase: NSEvent.Phase { inertiaPhase }
    override var timestamp: TimeInterval { sentTime }
}

private final class ScrollLiveLog: @unchecked Sendable {
    struct Sample: Sendable { let isScroll: Bool; let started: Double; let finished: Double }
    private let lock = NSLock()
    private var errors: [String] = []
    private var keys = 0
    private var downs = 0
    private var moves = 0
    private var scrolls = 0
    private var lastMovedPoint: NormalizedPoint?
    private var completedSamples: [Sample] = []
    var failures: [String] { lock.withLock { errors } }
    var keyCount: Int { lock.withLock { keys } }
    var touchDownCount: Int { lock.withLock { downs } }
    var moveCount: Int { lock.withLock { moves } }
    var scrollCount: Int { lock.withLock { scrolls } }
    var lastMove: NormalizedPoint? { lock.withLock { lastMovedPoint } }
    var samples: [Sample] { lock.withLock { completedSamples } }
    func failure(_ message: String) { lock.withLock { errors.append(message) } }
    func completed(_ action: InputAction, started: Double) {
        lock.withLock {
            let isScroll: Bool
            if case .scroll = action { isScroll = true } else { isScroll = false }
            completedSamples.append(Sample(isScroll: isScroll, started: started,
                finished: ProcessInfo.processInfo.systemUptime))
            switch action {
            case .key: keys += 1
            case .touch(.down, _, _): downs += 1
            case let .touch(.move, point, _): moves += 1; lastMovedPoint = point
            case .scroll: scrolls += 1
            default: break
            }
        }
    }
}

/// Cross-boundary evidence for real input → UIKit → decoded video. ACKs are
/// deliberately excluded: they do not prove that the guest page has moved.
private final class ScrollLiveMotionLog: @unchecked Sendable {
    struct Source {
        let uptime: Double
        let phase: TouchPhase
        let point: NormalizedPoint
    }
    struct Wheel {
        let uptime: Double
        let eventTimestamp: Double
        let dy: Double
        let phase: UInt
        let momentum: UInt
    }
    struct Frame { let uptime: Double; let visibleChange: Bool }
    private let lock = NSLock()
    private var sources: [Source] = []
    private var wheels: [Wheel] = []
    private var frames: [Frame] = []
    private var referencePixels: [UInt8] = []

    func source(_ action: InputAction) {
        guard case let .touch(phase, point, _) = action else { return }
        lock.withLock { sources.append(Source(uptime: ProcessInfo.processInfo.systemUptime, phase: phase, point: point)) }
    }

    func wheel(dy: Double, phase: NSEvent.Phase, momentum: NSEvent.Phase, timestamp: Double) {
        lock.withLock { wheels.append(Wheel(uptime: ProcessInfo.processInfo.systemUptime,
            eventTimestamp: timestamp, dy: dy, phase: phase.rawValue, momentum: momentum.rawValue)) }
    }

    func frame(_ frame: VideoFrame) {
        let buffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(buffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer) else { return }
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var pixels: [UInt8] = []
        // Sample the table region, excluding the status bar and recovery button.
        // This is content change evidence, independent of frame timestamps/FPS.
        for y in Swift.stride(from: height / 4, to: height * 9 / 10, by: max(1, height / 64)) {
            for x in Swift.stride(from: width / 20, to: width * 4 / 5, by: max(1, width / 96)) {
                pixels.append(bytes[y * stride + (planar ? x : x * 4 + 1)])
            }
        }
        let time = ProcessInfo.processInfo.systemUptime
        lock.withLock {
            // H.264 can change a few decoded pixel bits on an otherwise static
            // page. Accumulate until mean luma/green change exceeds 2/255;
            // exact pixel hashes would count codec noise as visible following.
            let difference = referencePixels.count == pixels.count && !pixels.isEmpty
                ? zip(referencePixels, pixels).reduce(0.0) { $0 + abs(Double($1.0) - Double($1.1)) } / Double(pixels.count)
                : 0
            let changed = difference > 2
            if changed || referencePixels.isEmpty { referencePixels = pixels }
            frames.append(Frame(uptime: time, visibleChange: changed))
            if frames.count > 10_000 { frames.removeFirst(2_000) }
        }
    }

    func report(name: String, start: Double, stopped: Double, released: Double,
                initialOffset: Double, state: ScrollLiveState,
                reverse: Bool, hold: Bool) throws -> [String: Any] {
        let (source, wheel, video) = lock.withLock {
            (sources.filter { $0.uptime >= start && $0.uptime <= released + 0.01 },
             wheels.filter { $0.uptime >= start && $0.uptime <= released + 0.01 },
             frames.filter { $0.uptime >= start - 0.2 && $0.uptime <= released + 0.3 })
        }
        let guest = state.events.filter { $0.uptime >= start && $0.uptime <= released + 0.3 }
        let touches = guest.filter { $0.kind == "touch" }
        guard let down = source.first(where: { $0.phase == .down }),
              let began = touches.first(where: { $0.phase == "began" }),
              let beganY = began.y, down.point.y > 0 else {
            throw ScrollLiveFailure(message: "\(name): fixture must publish native touch positions")
        }
        let nativeHeight = beganY / down.point.y
        let moves = touches.filter { $0.phase == "moved" && $0.y != nil }
        let offsets = guest.filter { $0.offset != nil }
        let changedFrames = video.filter { $0.visibleChange && $0.uptime >= start }.map(\.uptime)
        let firstWheel = wheel.first(where: { $0.dy != 0 })?.uptime ?? start
        var matched: [(source: Double, native: Double, hid: Double)] = []
        for touch in moves {
            guard let y = touch.y else { continue }
            let hidTime = touch.eventTimestamp ?? touch.uptime
            let contact = source.last(where: { $0.phase == .down && $0.uptime <= hidTime + 0.005 })?.uptime ?? start
            // Injection rounds to native pixels. Match only within this contact,
            // choosing the newest source point so reversals cannot use an old pass.
            if let event = source.last(where: { $0.phase == .move && $0.uptime >= contact
                && $0.uptime <= hidTime + 0.005 && abs($0.point.y * nativeHeight - y) <= 0.75 }) {
                matched.append((event.uptime, touch.uptime, hidTime))
            }
        }
        func percentiles(_ values: [Double]) -> [String: Any] {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return ["samples": 0] }
            return ["samples": sorted.count, "p50_ms": sorted[(sorted.count - 1) / 2],
                "p95_ms": sorted[Int(Double(sorted.count - 1) * 0.95)], "max_ms": sorted.last!]
        }
        var quarters: [[String: Any]] = []
        for index in 0..<4 {
            let lower = start + (stopped - start) * Double(index) / 4
            let upper = start + (stopped - start) * Double(index + 1) / 4
            let delivered = moves.filter { $0.uptime >= lower && $0.uptime < upper }
            let positions = offsets.filter { $0.uptime >= lower && $0.uptime < upper }.compactMap(\.offset)
            let deliveryTimes = [lower] + delivered.map(\.uptime) + [upper]
            let gaps = zip(deliveryTimes, deliveryTimes.dropFirst()).map { ($1 - $0) * 1000 }
            quarters.append(["quarter": index + 1, "native_moves": delivered.count,
                "max_native_delivery_gap_ms": gaps.max() ?? 0,
                "UIKit_offset_range_pt": (positions.max() ?? 0) - (positions.min() ?? 0),
                "decoded_content_changes": changedFrames.filter { $0 >= lower && $0 < upper }.count,
                "source_to_UIKit_touch": percentiles(matched.filter { $0.source >= lower && $0.source < upper }
                    .map { ($0.native - $0.source) * 1000 })])
        }
        var report: [String: Any] = ["scenario": name,
            "source_start_uptime": start, "source_stopped_uptime": stopped, "source_released_uptime": released,
            "first_native_down_ms": (began.uptime - firstWheel) * 1000,
            "source_to_UIKit_touch": percentiles(matched.map { ($0.native - $0.source) * 1000 }),
            "source_to_HID_timestamp": percentiles(matched.map { ($0.hid - $0.source) * 1000 }),
            "HID_timestamp_to_UIKit": percentiles(touches.compactMap { event in
                event.eventTimestamp.map { (event.uptime - $0) * 1000 }
            }), "matched_native_moves": matched.count, "native_moves": moves.count,
            "quarters": quarters,
            "first_100ms_native_moves": moves.filter { $0.uptime < firstWheel + 0.1 }.count,
            "first_100ms_decoded_content_changes": changedFrames.filter { $0 < firstWheel + 0.1 }.count,
            "first_100ms_samples": (1...4).map { tick -> [String: Any] in
                let limit = firstWheel + Double(tick) * 0.025
                return ["elapsed_ms": tick * 25,
                    "UIKit_offset_delta_pt": (offsets.last(where: { $0.uptime <= limit })?.offset ?? initialOffset) - initialOffset,
                    "native_moves_so_far": moves.filter { $0.uptime <= limit }.count,
                    "decoded_content_changes_so_far": changedFrames.filter { $0 <= limit }.count]
            },
            "source_wheels": wheel.map { event -> [String: Any] in ["uptime": event.uptime, "dy": event.dy,
                "eventTimestamp": event.eventTimestamp, "phase": event.phase, "momentum": event.momentum] },
            "source_touch_actions": source.map { event -> [String: Any] in ["uptime": event.uptime,
                "phase": String(describing: event.phase), "x": event.point.x, "y": event.point.y] }]
        if let firstOffset = offsets.first(where: { abs(($0.offset ?? initialOffset) - initialOffset) > 1 }) {
            report["first_UIKit_offset_ms"] = (firstOffset.uptime - firstWheel) * 1000
        }
        if let firstVideo = changedFrames.first { report["first_decoded_content_change_ms"] = (firstVideo - firstWheel) * 1000 }
        if let firstMove = moves.first { report["first_native_move_ms"] = (firstMove.uptime - firstWheel) * 1000 }
        if reverse {
            let reversalTime = wheel.first(where: { $0.dy > 0 })?.uptime ?? stopped
            var previous = offsets.last(where: { $0.uptime < reversalTime })?.offset ?? initialOffset
            for event in offsets where event.uptime >= reversalTime {
                guard let offset = event.offset else { continue }
                if offset < previous - 0.5 {
                    report["UIKit_reversal_ms"] = (event.uptime - reversalTime) * 1000
                    break
                }
                previous = offset
            }
        }
        if hold {
            let pauseOffsets = offsets.filter { $0.uptime >= stopped + 0.1 && $0.uptime < released }.compactMap(\.offset)
            report["held_pause_UIKit_drift_pt"] = (pauseOffsets.max() ?? 0) - (pauseOffsets.min() ?? 0)
            report["held_pause_native_moves_after_100ms"] = moves.filter { $0.uptime >= stopped + 0.1 && $0.uptime < released }.count
            report["held_pause_native_releases"] = touches.filter { ["ended", "cancelled"].contains($0.phase ?? "") && $0.uptime < released }.count
        }
        return report
    }
}
