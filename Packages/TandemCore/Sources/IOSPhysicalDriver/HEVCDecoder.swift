import CoreMedia
import CoreVideo
import DeviceCore
import Foundation
import VideoToolbox

struct HEVCParameterSets: Equatable {
    let vps: Data
    let sps: Data
    let pps: Data
}

enum HEVCParser {
    static func nals(_ annexB: Data) throws -> [Data] {
        let bytes = [UInt8](annexB)
        var starts: [(Int, Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if bytes[index + 2] == 1 { starts.append((index, 3)); index += 3; continue }
                if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    starts.append((index, 4)); index += 4; continue
                }
            }
            index += 1
        }
        guard let first = starts.first, bytes[..<first.0].allSatisfy({ $0 == 0 }) else { throw protocolError("HEVC 帧缺少 Annex-B 起始码") }
        return try starts.enumerated().map { offset, start in
            let end = offset + 1 < starts.count ? starts[offset + 1].0 : bytes.count
            let nal = Data(bytes[(start.0 + start.1)..<end])
            guard nal.count >= 2, nal[0] & 0x80 == 0, nal[1] & 7 != 0 else { throw protocolError("无效 HEVC NAL") }
            return nal
        }
    }
    static func type(_ nal: Data) -> UInt8 { (nal[nal.startIndex] >> 1) & 0x3f }
    static func parameterSets(_ nals: [Data]) -> HEVCParameterSets? {
        guard let vps = nals.last(where: { type($0) == 32 }),
              let sps = nals.last(where: { type($0) == 33 }),
              let pps = nals.last(where: { type($0) == 34 }) else { return nil }
        return .init(vps: vps, sps: sps, pps: pps)
    }
    static func avcc(_ nals: [Data]) -> Data {
        var result = Data()
        for nal in nals where type(nal) <= 31 {
            var length = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
            result.append(nal)
        }
        return result
    }
}

struct HEVCConfigurationAccumulator {
    private var nalsByType: [UInt8: Data] = [:]
    mutating func append(_ nals: [Data]) -> HEVCParameterSets? {
        for nal in nals where (32...34).contains(HEVCParser.type(nal)) { nalsByType[HEVCParser.type(nal)] = nal }
        return HEVCParser.parameterSets(Array(nalsByType.values))
    }
}

/// Used only by the serial video reader. Waits for each submitted access unit so encoded
/// dependencies never get dropped; observers may choose to retain only the latest frame.
final class USBHEVCDecoder: @unchecked Sendable {
    private let onFrame: @Sendable (VideoFrame) -> Void
    private var config: HEVCParameterSets?
    private var parameters = HEVCConfigurationAccumulator()
    private var format: CMVideoFormatDescription?
    private var session: VTDecompressionSession?
    init(onFrame: @escaping @Sendable (VideoFrame) -> Void) { self.onFrame = onFrame }
    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    func decode(_ packet: USBVideoPacket) throws {
        let nals = try HEVCParser.nals(packet.payload)
        let nextConfig = parameters.append(nals)
        let avcc = HEVCParser.avcc(nals)
        guard !avcc.isEmpty else { return }
        // Config NALs may arrive separately during rotation. Build only when the
        // next slice arrives, after all preceding parameter packets were collected.
        if let config = nextConfig, self.config != config {
            if let session { VTDecompressionSessionInvalidate(session) }
            session = nil
            format = nil
            self.config = nil
            var newFormat: CMVideoFormatDescription?
            let status = [UInt8](config.vps).withUnsafeBufferPointer { vps in
                [UInt8](config.sps).withUnsafeBufferPointer { sps in
                    [UInt8](config.pps).withUnsafeBufferPointer { pps in
                        CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                            allocator: kCFAllocatorDefault, parameterSetCount: 3,
                            parameterSetPointers: [vps.baseAddress!, sps.baseAddress!, pps.baseAddress!],
                            parameterSetSizes: [vps.count, sps.count, pps.count], nalUnitHeaderLength: 4,
                            extensions: nil, formatDescriptionOut: &newFormat)
                    }
                }
            }
            guard status == noErr, let newFormat else { throw protocolError("HEVC 格式创建失败 (\(status))") }
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                        kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any]]
            let createStatus = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: newFormat,
                decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary, outputCallback: nil,
                decompressionSessionOut: &session)
            guard createStatus == noErr else { throw protocolError("HEVC 解码器创建失败 (\(createStatus))") }
            self.format = newFormat
            self.config = config
        }
        guard let session, let format else { return } // Wait for first VPS/SPS/PPS.
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: avcc.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == noErr, let block else { throw protocolError("HEVC 内存块创建失败") }
        status = avcc.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: avcc.count) }
        guard status == noErr else { throw protocolError("HEVC 内存块写入失败") }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(clamping: packet.microseconds), timescale: 1_000_000), decodeTimeStamp: .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw protocolError("HEVC 样本创建失败") }
        let onFrame = self.onFrame
        let completion = HEVCDecodeCompletion()
        status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [._EnableAsynchronousDecompression], infoFlagsOut: nil) { status, _, image, pts, _ in
            completion.complete(status)
            if status == noErr, let image { onFrame(VideoFrame(pixelBuffer: image, presentationTime: pts)) }
        }
        guard status == noErr else { throw protocolError("HEVC 解码提交失败 (\(status))") }
        let waitStatus = VTDecompressionSessionWaitForAsynchronousFrames(session)
        guard waitStatus == noErr else { throw protocolError("HEVC 等待解码失败 (\(waitStatus))") }
        if let callbackStatus = completion.status, callbackStatus != noErr {
            throw protocolError("HEVC 解码失败 (\(callbackStatus))")
        }
    }
}

private final class HEVCDecodeCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var result: OSStatus?
    var status: OSStatus? { lock.withLock { result } }
    func complete(_ status: OSStatus) { lock.withLock { result = status } }
}
