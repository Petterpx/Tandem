import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import FBControlCore
import FBSimulatorControl
import FBVideoCore
import Foundation
import IOSurface
import VideoToolbox

/// Snapshots the live simulator surface before submitting it to hardware encoding.
/// There are at most two owned buffers in flight and one replaceable source request.
/// All conversion/encoding runs on this queue, never the HID/main actor.
final class SimulatorPreviewEncoder: @unchecked Sendable {
    private struct Source: @unchecked Sendable {
        let surface: IOSurface
        let geometry: SimulatorDisplayGeometry?
    }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.tandem.simulator.encode", qos: .userInteractive)
    private let consumer: SimulatorVideoConsumer
    private let logger: any ControlCoreLogger
    private let failure: @Sendable (any Error) -> Void
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private var latest: Source?
    private var scheduled = false
    private var closed = false
    private var inFlight = 0
    private var counts: [String: UInt] = ["callbacks": 0, "written": 0, "dropped": 0, "encode_errors": 0, "encoded_bytes": 0]
    // The following are confined to queue.
    private var session: VTCompressionSession?
    private var pool: CVPixelBufferPool?
    private var dimensions = CGSize.zero
    private var frameNumber: Int64 = 0

    init(consumer: SimulatorVideoConsumer, logger: any ControlCoreLogger, failure: @escaping @Sendable (any Error) -> Void) {
        self.consumer = consumer
        self.logger = logger
        self.failure = failure
    }
    var statistics: [String: UInt] { lock.withLock { counts } }

    func submit(surface: IOSurface, geometry: SimulatorDisplayGeometry?) {
        lock.withLock {
            guard !closed else { return }
            latest = Source(surface: surface, geometry: geometry)
            scheduleIfReady()
        }
    }
    /// Called only under lock; scheduling never captures a raw borrowed IOSurface pointer.
    private func scheduleIfReady() {
        guard !closed, !scheduled, latest != nil, inFlight < 2 else { return }
        scheduled = true
        queue.async { [self] in drain() }
    }
    private func drain() {
        while true {
            let source: Source? = lock.withLock {
                guard !closed, inFlight < 2, let source = latest else { scheduled = false; return nil }
                latest = nil
                inFlight += 1
                return source
            }
            guard let source else { return }
            do { try encode(source) }
            catch {
                completed()
                fail(error)
                return
            }
        }
    }

    private func encode(_ source: Source) throws {
        var image = CIImage(ioSurface: unsafeBitCast(source.surface, to: IOSurfaceRef.self), options: [.colorSpace: colorSpace])
        if let geometry = source.geometry, geometry.surfacePixelSize == image.extent.size {
            image = image.oriented(forExifOrientation: geometry.rotation.exifOrientation)
        }
        let scale = min(1, 1920 / max(image.extent.width, image.extent.height))
        let width = max(2, Int((image.extent.width * scale / 2).rounded()) * 2)
        let height = max(2, Int((image.extent.height * scale / 2).rounded()) * 2)
        try configure(width: width, height: height)
        guard let session, let pool else { throw HelperFailure(code: "CONNECTION_FAILED", message: "Video encoder is unavailable") }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else { throw HelperFailure(code: "CONNECTION_FAILED", message: "Video buffer pool exhausted (\(status))") }
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        image = image.transformed(by: CGAffineTransform(scaleX: Double(width) / image.extent.width, y: Double(height) / image.extent.height))
        // This materializes a private NV12 image. The encoder never retains the
        // simulator-owned IOSurface, which can change as soon as the next render starts.
        let seed = IOSurfaceGetSeed(source.surface)
        context.render(image, to: pixelBuffer, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: colorSpace)
        if IOSurfaceGetSeed(source.surface) != seed {
            // CoreImage reads can themselves advance the seed, even with a static
            // synthetic source. Count this observation without treating it as tearing.
            lock.withLock { counts["snapshot_seed_changes", default: 0] += 1 }
        }
        let pts = CMTime(value: frameNumber, timescale: 60)
        frameNumber += 1
        let result = VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer,
            presentationTimeStamp: pts, duration: CMTime(value: 1, timescale: 60),
            frameProperties: nil, infoFlagsOut: nil) { [weak self] status, flags, sample in
                guard let self else { return }
                defer { self.completed() }
                self.lock.withLock { self.counts["callbacks", default: 0] += 1 }
                guard status == noErr else {
                    self.lock.withLock { self.counts["encode_errors", default: 0] += 1 }
                    self.fail(HelperFailure(code: "CONNECTION_FAILED", message: "Hardware video encoding failed (\(status))"))
                    return
                }
                if flags.contains(.frameDropped) {
                    self.lock.withLock { self.counts["dropped", default: 0] += 1 }
                    return
                }
                guard let sample else {
                    self.fail(HelperFailure(code: "CONNECTION_FAILED", message: "Hardware video encoder returned no frame"))
                    return
                }
                do {
                    try AnnexBFrameWriter(codec: .h264).write(sample, to: self.consumer, logger: self.logger)
                    self.lock.withLock {
                        self.counts["written", default: 0] += 1
                        self.counts["encoded_bytes", default: 0] += UInt(CMSampleBufferGetTotalSampleSize(sample))
                    }
                } catch { self.fail(error) }
            }
        guard result == noErr else { throw HelperFailure(code: "CONNECTION_FAILED", message: "Hardware encoder rejected frame (\(result))") }
    }

    private func configure(width: Int, height: Int) throws {
        let size = CGSize(width: width, height: height)
        guard session == nil || dimensions != size else { return }
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        pool = nil
        let attributes: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any], kCVPixelBufferMetalCompatibilityKey: true]
        let poolStatus = CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 3] as CFDictionary, attributes as CFDictionary, &pool)
        guard poolStatus == kCVReturnSuccess else { throw HelperFailure(code: "CONNECTION_FAILED", message: "Cannot create video buffer pool (\(poolStatus))") }
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &created)
        guard status == noErr, let created else { throw HelperFailure(code: "CONNECTION_FAILED", message: "Cannot create hardware video encoder (\(status))") }
        session = created
        dimensions = size
        let properties: [CFString: Any] = [kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_AllowFrameReordering: false, kVTCompressionPropertyKey_MaxFrameDelayCount: 1,
            kVTCompressionPropertyKey_ExpectedFrameRate: 60, kVTCompressionPropertyKey_AverageBitRate: 12_000_000,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: 60,
            kVTCompressionPropertyKey_ProfileLevel: kVTProfileLevel_H264_High_AutoLevel]
        let configured = VTSessionSetProperties(created, propertyDictionary: properties as CFDictionary)
        guard configured == noErr else { throw HelperFailure(code: "CONNECTION_FAILED", message: "Cannot configure video encoder (\(configured))") }
        let prepared = VTCompressionSessionPrepareToEncodeFrames(created)
        guard prepared == noErr else { throw HelperFailure(code: "CONNECTION_FAILED", message: "Cannot prepare video encoder (\(prepared))") }
    }
    private func completed() {
        lock.withLock { inFlight -= 1; scheduleIfReady() }
    }
    private func fail(_ error: any Error) {
        let report = lock.withLock { guard !closed else { return false }; closed = true; latest = nil; return true }
        if report { consumer.close(); failure(error) }
    }
    func close() async {
        lock.withLock { closed = true; latest = nil }
        consumer.close()
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if let session {
                    VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
                    VTCompressionSessionInvalidate(session)
                }
                session = nil
                pool = nil
                continuation.resume()
            }
        }
    }
}
