import AVFoundation
import CoreMedia
import CoreVideo
import DeviceCore
import Foundation
import Testing
@testable import MediaKit

struct CanvasRecorderTests {
    private let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("canvas-recorder-\(UUID().uuidString).mp4")

    /// 合成与解码输出同格式的纯色 BGRA 帧。
    private func solidFrame(width: Int, height: Int, pts: CMTime = .invalid, gray: UInt8 = 0x80) throws -> VideoFrame {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary, &buffer)
        let pixelBuffer = try #require(status == kCVReturnSuccess ? buffer : nil)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        let base = try #require(CVPixelBufferGetBaseAddress(pixelBuffer))
        memset(base, Int32(gray), CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return VideoFrame(pixelBuffer: pixelBuffer, presentationTime: pts)
    }

    @Test func recordsAcrossRotationIntoFirstFrameCanvas() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = CanvasRecorder(url: url)
        // 30 帧 64×48（pts 0…29/30 s），再 30 帧 48×64（pts 30…59/30 s）。
        // 每帧间隔 10ms 模拟实时送帧：编码器未就绪时录制器会丢帧。
        for i in 0..<60 {
            let (w, h) = i < 30 ? (64, 48) : (48, 64)
            recorder.append(try solidFrame(width: w, height: h, pts: CMTime(value: CMTimeValue(i), timescale: 30)))
            try await Task.sleep(for: .milliseconds(10))
        }
        let summary = try await recorder.finish()
        let asset = AVURLAsset(url: summary.url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        #expect(try await track.load(.naturalSize) == CGSize(width: 64, height: 48))
        #expect(abs(try await asset.load(.duration).seconds - 2.0) < 0.1)
        #expect(abs(summary.duration - 2.0) < 0.1)
        #expect(summary.canvasSize == CGSize(width: 64, height: 48) && summary.fileSize > 0 && summary.thumbnailPNG != nil)
    }

    @Test func finishWithoutFramesThrowsAndLeavesNoFile() async {
        let recorder = CanvasRecorder(url: url)
        await #expect(throws: RecordingError.noFrames) { try await recorder.finish() }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func framesWithoutTimestampUseArrivalTime() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = CanvasRecorder(url: url)
        for _ in 0..<3 {
            recorder.append(try solidFrame(width: 64, height: 48))
            try await Task.sleep(for: .milliseconds(50))
        }
        let summary = try await recorder.finish()
        #expect(summary.duration > 0)
        #expect(try await AVURLAsset(url: summary.url).load(.duration).seconds > 0)
    }

    @Test func appendsDuringFinishAreIgnoredAndFinishReturns() async throws {
        defer { try? FileManager.default.removeItem(at: url) }
        let recorder = CanvasRecorder(url: url)
        let frame = try solidFrame(width: 64, height: 48)
        // 模拟解码线程持续送帧，finish 不能被拖住。
        let feeder = Task.detached {
            while !Task.isCancelled {
                recorder.append(frame)
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        try await Task.sleep(for: .milliseconds(200))
        let summary = try await recorder.finish()
        feeder.cancel()
        #expect(summary.fileSize > 0)
        recorder.append(frame)  // finish 之后再送帧不应崩溃
    }
}
