import CoreVideo
import MediaKit
import CoreMedia
import DeviceCore
import Foundation
import Testing
@testable import IOSSimulatorDriver

/// Run only against a disposable simulator displaying a continuous 60 Hz animation.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TANDEM_VIDEO_BENCHMARK"] == "1"))
struct SimulatorPerformanceLiveTests {
    @Test func continuousAnimationHasBoundedFrameAndInputLatency() async throws {
        let env = ProcessInfo.processInfo.environment
        let udid = try #require(env["TANDEM_TEST_SIMULATOR"])
        let helper = URL(fileURLWithPath: try #require(env["TANDEM_SIMULATOR_HELPER"]))
        let device = DeviceInfo(serial: udid, platform: .ios, name: "Video benchmark", state: .connected, connection: .simulator)
        let session = IOSSimulatorSession(device: device, helperURL: helper)
        let measurements = FrameMeasurements()
        let token = session.addFrameObserver { measurements.append($0) }
        await session.start()
        do {
            for await event in session.events {
                if case .state(.running) = event { break }
                if case let .state(.failed(error)) = event { throw error }
            }
            try await Task.sleep(for: .seconds(2))
            measurements.reset()
            let start = ProcessInfo.processInfo.systemUptime
            var rpcMilliseconds: [Double] = []
            var savedRotation = false
            for _ in 0..<20 {
                try await Task.sleep(for: .milliseconds(500))
                let sent = ProcessInfo.processInfo.systemUptime
                try await session.sendChecked(.key(.enter))
                rpcMilliseconds.append((ProcessInfo.processInfo.systemUptime - sent) * 1000)
                if !savedRotation, let path = env["TANDEM_ROTATION_FRAME"], let frame = session.latestFrame(),
                   CVPixelBufferGetWidth(frame.pixelBuffer) > CVPixelBufferGetHeight(frame.pixelBuffer) {
                    try ScreenshotEncoder.encodeFramePNG(frame.pixelBuffer).data.write(to: URL(fileURLWithPath: path))
                    savedRotation = true
                }
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            let result = measurements.result(elapsed: elapsed, rpc: rpcMilliseconds)
            if let stats = try? await session.videoStatistics() { print("TANDEM_NATIVE_STATS \(stats)") }
            if let path = env["TANDEM_BENCHMARK_FRAME"], let frame = session.latestFrame() {
                try ScreenshotEncoder.encodeFramePNG(frame.pixelBuffer).data.write(to: URL(fileURLWithPath: path))
            }
            print("TANDEM_VIDEO_BENCHMARK \(result.json)")
            #expect(result.fps >= 50, "Continuous animation must deliver at least 50 decoded frames/s")
            #expect(result.rpcP95 < 150, "Video must not block HID acknowledgements")
            session.removeFrameObserver(token)
            await session.stop()
        } catch {
            session.removeFrameObserver(token)
            await session.stop()
            throw error
        }
    }
}

private final class FrameMeasurements: @unchecked Sendable {
    private let lock = NSLock()
    private var arrivals: [Double] = []
    private var latencies: [Double] = []
    private var changed = 0
    private var signature: UInt32?
    private var dimensions: [Int] = []
    private var dimensionsHistory: [[Int]] = []
    func reset() { lock.withLock { arrivals.removeAll(); latencies.removeAll(); changed = 0; signature = nil } }
    func append(_ frame: VideoFrame) {
        let now = ProcessInfo.processInfo.systemUptime
        let buffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let base = CVPixelBufferGetBaseAddress(buffer)!
        let pixel = base.loadUnaligned(fromByteOffset: (height * 3 / 4) * CVPixelBufferGetBytesPerRow(buffer) + (width / 2) * 4, as: UInt32.self)
        CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        lock.withLock {
            if signature != pixel { changed += 1; signature = pixel }
            if dimensions != [width, height] { dimensionsHistory.append([width, height]) }
            dimensions = [width, height]
            arrivals.append(now)
            let pts = CMTimeGetSeconds(frame.presentationTime)
            if pts > 0, pts <= now, now - pts < 10 { latencies.append((now - pts) * 1000) }
        }
    }
    struct Result {
        let fps: Double
        let rpcP95: Double
        let json: String
    }
    func result(elapsed: Double, rpc: [Double]) -> Result {
        lock.withLock {
            func percentile(_ samples: [Double], _ p: Double) -> Double {
                let sorted = samples.sorted()
                return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
            }
            let intervals = zip(arrivals.dropFirst(), arrivals).map { ($0 - $1) * 1000 }
            let fps = Double(arrivals.count) / elapsed
            let object: [String: Any] = ["decoded_frames": arrivals.count, "seconds": elapsed, "fps": fps,
                "changed_background_samples": changed, "changed_samples_per_second": Double(changed) / elapsed, "dimensions": dimensions, "dimensions_history": dimensionsHistory,
                "interval_p50_ms": percentile(intervals, 0.5), "interval_p95_ms": percentile(intervals, 0.95),
                "encoder_output_to_decoded_p50_ms": percentile(latencies, 0.5), "encoder_output_to_decoded_p95_ms": percentile(latencies, 0.95),
                "rpc_p50_ms": percentile(rpc, 0.5), "rpc_p95_ms": percentile(rpc, 0.95)]
            let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            return Result(fps: fps, rpcP95: percentile(rpc, 0.95), json: String(decoding: data, as: UTF8.self))
        }
    }
}
