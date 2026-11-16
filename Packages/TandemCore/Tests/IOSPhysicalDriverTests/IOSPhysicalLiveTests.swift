import CoreVideo
import DeviceCore
import Foundation
import MediaKit
import Testing
@testable import IOSPhysicalDriver

/// Explicitly opted-in physical iPhone test. HID is a separate opt-in: position the
/// test phone on a safe Settings list before enabling TANDEM_TEST_IPHONE_TOUCH=1.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["TANDEM_TEST_IPHONE"] != nil
        && ProcessInfo.processInfo.environment["TANDEM_IOS_USB_HELPER"] != nil))
struct IOSPhysicalLiveTests {
    @Test func nativeHEVCStreamingScreenshotAndOptionalHeldTouch() async throws {
        let env = ProcessInfo.processInfo.environment
        let udid = try #require(env["TANDEM_TEST_IPHONE"])
        let helper = URL(fileURLWithPath: try #require(env["TANDEM_IOS_USB_HELPER"]))
        let device = DeviceInfo(serial: udid, platform: .ios, name: "Integration iPhone", state: .connected, connection: .usb)
        let session = IOSPhysicalSession(device: device, helperURL: helper)
        let frames = FrameCount()
        let token = session.addFrameObserver { _ in frames.increment() }
        let states = LiveStateLog()
        var consumer = Self.observe(session.events, into: states)
        await session.start()
        do {
            for _ in 0..<500 {
                if session.latestFrame() != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let frame = try #require(session.latestFrame(), "Native HEVC decoder did not deliver a first frame")
            #expect(CVPixelBufferGetWidth(frame.pixelBuffer) > 0)
            #expect(CVPixelBufferGetHeight(frame.pixelBuffer) > 0)
            #expect(CVPixelBufferGetIOSurface(frame.pixelBuffer) != nil)
            #expect(frame.presentationTime.timescale == 1_000_000)
            let png = try ScreenshotEncoder.encodeFramePNG(frame.pixelBuffer).data
            #expect(png.starts(with: [137,80,78,71,13,10,26,10]))
            let before = frames.value
            try await Task.sleep(for: .seconds(2))
            #expect(frames.value - before >= 20)
            print("iPhone native HEVC: \(CVPixelBufferGetWidth(frame.pixelBuffer))x\(CVPixelBufferGetHeight(frame.pixelBuffer)), \(frames.value - before) frames / 2s")
            if env["TANDEM_TEST_IPHONE_TOUCH"] == "1" {
                for gesture in 1...2 {
                    let before = frames.value
                    try await session.sendChecked(.touch(.down, .init(x: 0.7, y: 0.72), pointer: .ai))
                    for step in 1...8 {
                        try await Task.sleep(for: .milliseconds(40))
                        try await session.sendChecked(.touch(.move, .init(x: 0.7, y: 0.72 - Double(step) * 0.035), pointer: .ai))
                    }
                    let held = frames.value - before
                    try await session.sendChecked(.touch(.up, .init(x: 0.7, y: 0.44), pointer: .ai))
                    #expect(held >= 3, "Video must continue while raw HID contact is held")
                    print("iPhone held gesture \(gesture): \(held) decoded frames during active contact")
                    try await Task.sleep(for: .milliseconds(150))
                }
            }
            try await eventually { states.matches(frame) }
            await session.stop()
            #expect(session.latestFrame() == nil)
            consumer.cancel()
            await consumer.value
            // Reuse the exact cached session and replace its cancelled consumer.
            consumer = Self.observe(session.events, into: states)
            await session.start()
            for _ in 0..<500 {
                if session.latestFrame() != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            let restarted = try #require(session.latestFrame(), "Cached session did not restart")
            try await eventually { states.matches(restarted) }
            let beforeRestartFrames = frames.value
            try await Task.sleep(for: .milliseconds(250))
            #expect(frames.value - beforeRestartFrames >= 3)
            await session.stop()
            consumer.cancel()
            await consumer.value
            session.removeFrameObserver(token)
            #expect(session.latestFrame() == nil)
            #expect(session.activeSerial == nil)
        } catch {
            await session.stop()
            consumer.cancel()
            await consumer.value
            session.removeFrameObserver(token)
            throw error
        }
    }
    private static func observe(_ events: AsyncStream<SessionEvent>, into states: LiveStateLog) -> Task<Void, Never> {
        Task { for await event in events { states.append(event) } }
    }
}

private final class LiveStateLog: @unchecked Sendable {
    private let lock = NSLock()
    private var last: SessionState = .idle
    func append(_ event: SessionEvent) { if case let .state(state) = event { lock.withLock { last = state } } }
    func matches(_ frame: VideoFrame) -> Bool {
        lock.withLock { last == .running(width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer)) }
    }
}
