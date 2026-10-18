import CoreVideo
import DeviceCore
import Foundation
import os
import Testing
@testable import AndroidDriver

struct H264DecoderTests {
    private static let startCode = Data([0, 0, 0, 1])

    /// 返回 (config 包, 帧包列表)。
    private func loadFixture() throws -> (config: Data, frames: [Data]) {
        let url = try #require(Bundle.module.url(forResource: "testsrc-64x48", withExtension: "h264", subdirectory: "Fixtures"))
        let nals = H264Parser.nalUnits(annexB: try Data(contentsOf: url))
        var config = Data()
        var frames: [Data] = []
        for nal in nals {
            switch H264Parser.nalType(nal) {
            case 7, 8: config.append(Self.startCode + nal)
            case 1, 5: frames.append(Self.startCode + nal)
            default: break
            }
        }
        return (config, frames)
    }

    /// 收集帧，最多等待 timeout 秒；达到 expected 帧即提前返回。
    private func collect(_ stream: AsyncStream<VideoFrame>, expected: Int, timeout: Double = 2) async -> [VideoFrame] {
        await withTaskGroup(of: [VideoFrame].self) { group in
            group.addTask {
                var out: [VideoFrame] = []
                for await f in stream {
                    out.append(f)
                    if out.count >= expected { break }
                }
                return out
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    @Test func decodesFixtureToBGRAFrames() async throws {
        let fx = try loadFixture()
        #expect(!fx.config.isEmpty && fx.frames.count == 5)
        let (stream, cont) = AsyncStream<VideoFrame>.makeStream()
        let decoder = H264Decoder { cont.yield($0) }
        decoder.decode(config: fx.config)
        for (i, f) in fx.frames.enumerated() { decoder.decode(frame: f, pts: UInt64(i) * 100_000) }
        let frames = await collect(stream, expected: fx.frames.count)
        #expect(frames.count >= 1)
        let pb = try #require(frames.first?.pixelBuffer)
        #expect(CVPixelBufferGetWidth(pb) == 64 && CVPixelBufferGetHeight(pb) == 48)
        #expect(CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA)
        #expect(CVPixelBufferGetIOSurface(pb) != nil)
    }

    @Test func framesBeforeConfigAreDropped() async throws {
        let fx = try loadFixture()
        let (stream, cont) = AsyncStream<VideoFrame>.makeStream()
        let decoder = H264Decoder { cont.yield($0) }
        for (i, f) in fx.frames.enumerated() { decoder.decode(frame: f, pts: UInt64(i)) }
        let frames = await collect(stream, expected: 1, timeout: 0.3)
        #expect(frames.isEmpty)
    }

    @Test func resetDropsFramesUntilNextConfig() async throws {
        let fx = try loadFixture()
        let count = OSAllocatedUnfairLock(initialState: 0)
        let (stream, cont) = AsyncStream<VideoFrame>.makeStream()
        let decoder = H264Decoder { count.withLock { $0 += 1 }; cont.yield($0) }
        decoder.decode(config: fx.config)
        decoder.reset()
        decoder.decode(frame: fx.frames[0], pts: 0)
        try await Task.sleep(for: .milliseconds(300))
        #expect(count.withLock { $0 } == 0)
        decoder.decode(config: fx.config)
        decoder.decode(frame: fx.frames[0], pts: 0)
        #expect(await collect(stream, expected: 1).count == 1)
    }

    @Test func identicalConfigKeepsDecoding() async throws {
        let fx = try loadFixture()
        let (stream, cont) = AsyncStream<VideoFrame>.makeStream()
        let decoder = H264Decoder { cont.yield($0) }
        decoder.decode(config: fx.config)
        decoder.decode(frame: fx.frames[0], pts: 0)
        decoder.decode(config: fx.config)
        decoder.decode(frame: fx.frames[1], pts: 100_000)
        #expect(await collect(stream, expected: 2).count == 2)
    }

    @Test func garbageInputDoesNotCrash() async throws {
        let fx = try loadFixture()
        let decoder = H264Decoder { _ in }
        decoder.decode(config: Data([1, 2, 3]))
        decoder.decode(frame: Data(), pts: 0)
        decoder.decode(config: fx.config)
        decoder.decode(frame: Self.startCode + Data([0x65, 0xFF, 0xFF]), pts: 0)
        decoder.decode(frame: Data([9, 9]), pts: 0)
    }
}
