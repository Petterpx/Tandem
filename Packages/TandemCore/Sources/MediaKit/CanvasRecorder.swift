import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import DeviceCore
import Foundation
import os
import QuartzCore

public struct RecordingSummary: Sendable, Equatable {
    public let url: URL
    /// 秒
    public let duration: Double
    public let canvasSize: CGSize
    public let fileSize: Int64
    /// 首帧缩略图
    public let thumbnailPNG: Data?

    public init(url: URL, duration: Double, canvasSize: CGSize, fileSize: Int64, thumbnailPNG: Data?) {
        self.url = url
        self.duration = duration
        self.canvasSize = canvasSize
        self.fileSize = fileSize
        self.thumbnailPNG = thumbnailPNG
    }
}

public enum RecordingError: LocalizedError, Equatable {
    /// 一帧都没写入，不生成文件。
    case noFrames
    case writerFailed(String)

    public var errorDescription: String? {
        switch self {
        case .noFrames: "未收到画面"
        case .writerFailed(let message): "录屏写入失败：\(message)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .noFrames: nil
        case .writerFailed: "请检查录屏目录的磁盘空间与权限"
        }
    }
}

/// 固定画布录屏：画布由首帧尺寸确定，之后每帧等比缩放、居中、黑色填充，H.264 写 mp4。
/// append 可从解码线程调用；所有写入在内部串行队列上进行。finish 开始后再 append 的帧直接忽略。
public final class CanvasRecorder: @unchecked Sendable {
    private struct Output {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let canvas: CGSize
    }

    private static let logger = Logger(subsystem: "dev.tandem", category: "CanvasRecorder")
    /// 缩略图最长边（像素）
    private static let thumbnailMaxSide: CGFloat = 480
    /// 只有一帧时，按 30fps 给最后一帧留出显示时长。
    private static let fallbackInterval = CMTime(value: 1, timescale: 30)

    private let url: URL
    private let bitRate: Int
    private let queue = DispatchQueue(label: "dev.tandem.CanvasRecorder")
    private let lock = NSLock()
    private var accepting = true  // 由 lock 保护

    // 以下只在 queue 上访问
    private var output: Output?
    private var fileCreated = false
    private var failure: String?
    private var firstPTS: CMTime = .invalid
    private var firstArrival: CFTimeInterval = 0
    private var lastTime: CMTime = .invalid
    private var lastInterval: CMTime = .invalid
    private var framesWritten = 0
    private var thumbnail: Data?
    private var result: Result<RecordingSummary, RecordingError>?
    private var waiters: [@Sendable (Result<RecordingSummary, RecordingError>) -> Void] = []
    /// 不做色彩管理：缩放后的帧与直接写入的帧像素一致。
    private lazy var context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    public init(url: URL, bitRate: Int = 8_000_000) {
        self.url = url
        self.bitRate = bitRate
    }

    public func append(_ frame: VideoFrame) {
        let arrival = CACurrentMediaTime()
        guard lock.withLock({ accepting }) else { return }
        queue.async { [self] in write(frame, arrival: arrival) }
    }

    public func finish() async throws -> RecordingSummary {
        let finishArrival = CACurrentMediaTime()
        lock.withLock { accepting = false }
        // 已在队列中的帧先写完，再收尾。
        let result = await withCheckedContinuation { (cont: CheckedContinuation<Result<RecordingSummary, RecordingError>, Never>) in
            queue.async { [self] in finalize(finishArrival: finishArrival) { cont.resume(returning: $0) } }
        }
        return try result.get()
    }

    // MARK: - 队列内

    private func write(_ frame: VideoFrame, arrival: CFTimeInterval) {
        guard failure == nil, result == nil, waiters.isEmpty else { return }
        if output == nil {
            start(with: frame, arrival: arrival)
            guard output != nil else { return }
        }
        guard let output else { return }

        // 帧时间：设备 PTS 相对首帧；没有时间戳时用到达时间相对首帧。
        let time: CMTime
        if frame.presentationTime.isValid, firstPTS.isValid {
            time = frame.presentationTime - firstPTS
        } else {
            time = CMTime(seconds: arrival - firstArrival, preferredTimescale: 1_000_000)
        }
        if time < .zero || (lastTime.isValid && time <= lastTime) { return }  // 时间不递增：丢弃
        guard output.input.isReadyForMoreMediaData else { return }  // 编码器忙：丢弃
        guard let buffer = canvasBuffer(for: frame.pixelBuffer, output: output) else { return }

        guard output.adaptor.append(buffer, withPresentationTime: time) else {
            if output.writer.status == .failed {
                failure = output.writer.error?.localizedDescription ?? "写入失败"
                Self.logger.error("写入帧失败：\(self.failure ?? "", privacy: .public)")
            }
            return
        }
        if lastTime.isValid { lastInterval = time - lastTime }
        lastTime = time
        framesWritten += 1
    }

    /// 首帧：确定画布、创建 writer、生成缩略图。
    private func start(with frame: VideoFrame, arrival: CFTimeInterval) {
        let size = CGSize(width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer))
        let canvas = CanvasLayout.canvasSize(for: size)
        guard canvas.width > 0, canvas.height > 0 else { return }
        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(canvas.width),
                AVVideoHeightKey: Int(canvas.height),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: bitRate],
            ])
            input.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(canvas.width),
                kCVPixelBufferHeightKey as String: Int(canvas.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
            guard writer.canAdd(input) else { throw RecordingError.writerFailed("无法添加视频轨道") }
            writer.add(input)
            guard writer.startWriting() else {
                throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "无法开始写入")
            }
            fileCreated = true
            writer.startSession(atSourceTime: .zero)
            output = Output(writer: writer, input: input, adaptor: adaptor, canvas: canvas)
        } catch let RecordingError.writerFailed(message) {
            failure = message
        } catch {
            failure = error.localizedDescription
        }
        if let failure {
            Self.logger.error("创建 writer 失败：\(failure, privacy: .public)")
            return
        }
        firstPTS = frame.presentationTime
        firstArrival = arrival
        thumbnail = makeThumbnail(frame.pixelBuffer)
    }

    /// 尺寸与画布相同直接用原 buffer；否则从缓冲池取一块，黑底上按 fit 矩形缩放平移绘入。
    private func canvasBuffer(for source: CVPixelBuffer, output: Output) -> CVPixelBuffer? {
        let extent = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(source), height: CVPixelBufferGetHeight(source))
        if extent.size == output.canvas { return source }
        guard let pool = output.adaptor.pixelBufferPool else { return nil }
        var target: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &target) == kCVReturnSuccess,
              let target else { return nil }
        let bounds = CGRect(origin: .zero, size: output.canvas)
        let rect = CanvasLayout.fit(extent.size, in: output.canvas)
        let placed = CIImage(cvPixelBuffer: source)
            .transformed(by: CGAffineTransform(scaleX: rect.width / extent.width, y: rect.height / extent.height)
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
        let image = placed.composited(over: CIImage(color: .black).cropped(to: bounds))
        context.render(image, to: target, bounds: bounds, colorSpace: nil)
        CVBufferPropagateAttachments(source, target)  // 沿用源帧的色彩标记，与直接写入的帧一致
        return target
    }

    private func makeThumbnail(_ buffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer)
        let scale = min(1, Self.thumbnailMaxSide / max(image.extent.width, image.extent.height))
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let sRGB = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return context.pngRepresentation(of: scaled, format: .RGBA8, colorSpace: sRGB)
    }

    private func finalize(finishArrival: CFTimeInterval, completion: @escaping @Sendable (Result<RecordingSummary, RecordingError>) -> Void) {
        // 重复调用 finish：返回同一结果；收尾进行中则一起等。
        if let result { return completion(result) }
        waiters.append(completion)
        guard waiters.count == 1 else { return }

        guard let output, failure == nil, framesWritten > 0 else {
            output?.writer.cancelWriting()
            removeCreatedFile()
            return complete(.failure(failure.map(RecordingError.writerFailed) ?? .noFrames))
        }

        // 结束时间取「最后一帧再加一个帧间隔」与「首帧以来的实际耗时」中较大者，画面静止也不会让文件变短。
        let interval = lastInterval.isValid ? lastInterval : Self.fallbackInterval
        let elapsed = CMTime(seconds: finishArrival - firstArrival, preferredTimescale: 1_000_000)
        let end = max(lastTime + interval, elapsed)
        output.input.markAsFinished()
        output.writer.endSession(atSourceTime: end)
        output.writer.finishWriting { [self] in
            queue.async { [self] in didFinishWriting(end: end) }
        }
    }

    private func didFinishWriting(end: CMTime) {
        guard let output else { return }
        guard output.writer.status == .completed else {
            let message = output.writer.error?.localizedDescription ?? "写入未完成"
            Self.logger.error("结束写入失败：\(message, privacy: .public)")
            removeCreatedFile()
            return complete(.failure(.writerFailed(message)))
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        complete(.success(RecordingSummary(
            url: url, duration: end.seconds, canvasSize: output.canvas, fileSize: size, thumbnailPNG: thumbnail
        )))
    }

    private func complete(_ value: Result<RecordingSummary, RecordingError>) {
        result = value
        waiters.forEach { $0(value) }
        waiters = []
    }

    private func removeCreatedFile() {
        guard fileCreated else { return }  // 不删除并非本录制创建的文件
        try? FileManager.default.removeItem(at: url)
    }
}
