import CoreMedia
import CoreVideo
import DeviceCore
import Foundation
import os
import VideoToolbox

protocol VideoDecoding: AnyObject, Sendable {
    /// 用 SPS/PPS 建 CMVideoFormatDescription；与当前不同则重建 VTDecompressionSession。
    func decode(config annexB: Data)
    func decode(frame annexB: Data, pts: UInt64)
    /// 销毁 session，等待下一个 config。
    func reset()
}

/// VideoToolbox 硬解 H.264，输出 BGRA、IOSurface 支撑的 CVPixelBuffer。解码错误只记录日志。
final class H264Decoder: VideoDecoding, @unchecked Sendable {
    private struct State {
        var session: VTDecompressionSession?
        var format: CMVideoFormatDescription?
        var config: (sps: Data, pps: Data)?
    }

    private static let logger = Logger(subsystem: "dev.magicdevx", category: "H264Decoder")

    private let onFrame: @Sendable (VideoFrame) -> Void
    private let lock = NSLock()
    private var state = State()  // 由 lock 保护

    init(onFrame: @escaping @Sendable (VideoFrame) -> Void) {
        self.onFrame = onFrame
    }

    deinit { reset() }

    func decode(config annexB: Data) {
        guard let (sps, pps) = H264Parser.parameterSets(annexB: annexB) else {
            Self.logger.error("config 包缺少 SPS/PPS，已忽略")
            return
        }
        lock.lock()
        defer { lock.unlock() }
        if let old = state.config, old.sps == sps, old.pps == pps, state.session != nil { return }
        Self.invalidate(&state)
        guard let format = Self.makeFormat(sps: sps, pps: pps) else { return }
        guard let session = Self.makeSession(format: format) else { return }
        state.config = (sps, pps)
        state.format = format
        state.session = session
    }

    func decode(frame annexB: Data, pts: UInt64) {
        lock.lock()
        let (session, format) = (state.session, state.format)
        lock.unlock()
        guard let session, let format else { return }  // 无 config：丢弃
        let avcc = H264Parser.avcc(fromAnnexB: annexB)
        guard !avcc.isEmpty, let sample = Self.makeSampleBuffer(avcc: avcc, format: format, pts: pts) else { return }
        let onFrame = self.onFrame
        let status = VTDecompressionSessionDecodeFrame(
            session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil
        ) { status, _, image, _, _ in
            guard status == noErr, let image else {
                Self.logger.error("解码失败 status=\(status)")
                return
            }
            onFrame(VideoFrame(pixelBuffer: image))
        }
        if status != noErr { Self.logger.error("提交解码失败 status=\(status)") }
    }

    func reset() {
        lock.lock()
        Self.invalidate(&state)
        lock.unlock()
    }

    // MARK: - 私有

    private static func invalidate(_ s: inout State) {
        if let session = s.session { VTDecompressionSessionInvalidate(session) }
        s = State()
    }

    private static func makeFormat(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var format: CMVideoFormatDescription?
        let status = [UInt8](sps).withUnsafeBufferPointer { sp in
            [UInt8](pps).withUnsafeBufferPointer { pp in
                let pointers = [sp.baseAddress!, pp.baseAddress!]
                let sizes = [sp.count, pp.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: pointers, parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &format)
            }
        }
        if status != noErr { logger.error("创建 FormatDescription 失败 status=\(status)") }
        return status == noErr ? format : nil
    }

    private static func makeSession(format: CMVideoFormatDescription) -> VTDecompressionSession? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
        ]
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault, formatDescription: format,
            decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary,
            outputCallback: nil, decompressionSessionOut: &session)
        if status != noErr { logger.error("创建 VTDecompressionSession 失败 status=\(status)") }
        return status == noErr ? session : nil
    }

    private static func makeSampleBuffer(avcc: Data, format: CMVideoFormatDescription, pts: UInt64) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { return nil }
        status = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard status == noErr else { return nil }
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(clamping: pts), timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        return status == noErr ? sample : nil
    }
}
