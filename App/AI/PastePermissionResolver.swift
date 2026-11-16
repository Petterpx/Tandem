import CoreImage
import DeviceCore
import Foundation
import Vision

/// Local OCR for the system paste dialog immediately following our own paste.
/// No image is persisted or sent to a model. Ambiguous recognition does nothing.
enum PastePermissionResolver {
    struct TextRegion: Sendable {
        let text: String
        let bounds: CGRect // Vision normalized coordinates, origin bottom-left.
        let confidence: Float
    }

    private static let gate = OCRGate()
    private static let imageContext = CIContext(options: [.cacheIntermediates: false])

    static func resolve(_ frame: VideoFrame) async -> DeviceCore.NormalizedPoint? {
        let work = RecognitionWork(frame: frame)
        return await gate.run(timeout: 0.6, worker: { work.recognize() }, cancel: { work.request.cancel() })
    }

    private final class RecognitionWork: @unchecked Sendable {
        let frame: VideoFrame
        let request = VNRecognizeTextRequest()
        init(frame: VideoFrame) { self.frame = frame }

        func recognize() -> DeviceCore.NormalizedPoint? {
            // Revision 3 may need an unavailable E5 model on macOS 27. The
            // installed revision 2 recognizes this system dialog locally.
            request.revision = VNRecognizeTextRequestRevision2
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.usesLanguageCorrection = true
            // Resize first, then recognize only the verified system-dialog
            // band. Convert Vision crop coordinates back to the full frame.
            // Let Vision select GPU/ANE rather than CPU-only.
            let source = CIImage(cvPixelBuffer: frame.pixelBuffer)
            let factor = min(1, 1280 / max(source.extent.width, source.extent.height))
            let scaled = source.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            guard let full = imageContext.createCGImage(scaled, from: scaled.extent) else { return nil }
            let crop = CGRect(x: Double(full.width) * 0.08, y: Double(full.height) * 0.35,
                              width: Double(full.width) * 0.84, height: Double(full.height) * 0.32)
            guard let image = full.cropping(to: crop) else { return nil }
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                let regions = (request.results ?? []).compactMap { observation -> TextRegion? in
                    guard let text = observation.topCandidates(1).first else { return nil }
                    let box = observation.boundingBox
                    let fullBox = CGRect(x: 0.08 + box.minX * 0.84, y: (1 - 0.35 - 0.32) + box.minY * 0.32,
                                         width: box.width * 0.84, height: box.height * 0.32)
                    return TextRegion(text: text.string, bounds: fullBox, confidence: text.confidence)
                }
                return button(in: regions)
            } catch { return nil }
        }
    }

    /// One worker owns the OCR slot until the underlying operation exits, even
    /// if its waiter timed out. Late results cannot resume or trigger a click.
    final class OCRGate: @unchecked Sendable {
        private let lock = NSLock()
        private var busy = false

        func run(timeout: TimeInterval, worker: @escaping @Sendable () -> DeviceCore.NormalizedPoint?,
                 cancel: @escaping @Sendable () -> Void = {}) async -> DeviceCore.NormalizedPoint? {
            let acquired = lock.withLock { () -> Bool in
                guard !busy else { return false }
                busy = true
                return true
            }
            guard acquired else { return nil }
            let completion = Completion(cancel: cancel)
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    completion.install(continuation)
                    if Task.isCancelled { completion.finish(nil, cancelling: true) }
                    DispatchQueue.global(qos: .userInitiated).async {
                        defer { self.lock.withLock { self.busy = false } }
                        guard !completion.isFinished else { return }
                        completion.finish(worker())
                    }
                    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                        completion.finish(nil, cancelling: true)
                    }
                }
            } onCancel: {
                completion.finish(nil, cancelling: true)
            }
        }

        private final class Completion: @unchecked Sendable {
            private let lock = NSLock()
            private var continuation: CheckedContinuation<DeviceCore.NormalizedPoint?, Never>?
            private var finished = false
            private let cancel: @Sendable () -> Void
            init(cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
            var isFinished: Bool { lock.withLock { finished } }

            func install(_ continuation: CheckedContinuation<DeviceCore.NormalizedPoint?, Never>) {
                let completed = lock.withLock { () -> Bool in
                    guard !finished else { return true }
                    self.continuation = continuation
                    return false
                }
                if completed { continuation.resume(returning: nil) }
            }

            func finish(_ value: DeviceCore.NormalizedPoint?, cancelling: Bool = false) {
                let result = lock.withLock { () -> (Bool, CheckedContinuation<DeviceCore.NormalizedPoint?, Never>?) in
                    guard !finished else { return (false, nil) }
                    finished = true
                    let waiting = continuation
                    continuation = nil
                    return (true, waiting)
                }
                guard result.0 else { return }
                result.1?.resume(returning: value)
                if cancelling { cancel() }
            }
        }
    }

    static func button(in regions: [TextRegion]) -> DeviceCore.NormalizedPoint? {
        func normalized(_ value: String) -> String {
            value.lowercased().replacingOccurrences(of: "’", with: "'")
                .filter { !$0.isWhitespace }
        }
        let allowLabels: Set<String> = ["允许粘贴", "允許貼上", "allowpaste"]
        let denyLabels: Set<String> = ["不允许粘贴", "不允許貼上", "don'tallow", "don'tallowpaste"]
        // Count all exact matches before confidence filtering: a second faint
        // match is still ambiguous, rather than permission to select one.
        let allow = regions.filter { allowLabels.contains(normalized($0.text)) }
        let deny = regions.filter { denyLabels.contains(normalized($0.text)) }
        guard allow.count == 1, deny.count == 1, let yes = allow.first, let no = deny.first,
              yes.confidence >= 0.85, no.confidence >= 0.85 else { return nil }
        let a = yes.bounds, b = no.bounds
        func isInsideModal(_ rectangle: CGRect) -> Bool {
            let hasSize = rectangle.width > 0 && rectangle.height > 0
            let inHorizontalRange = rectangle.minX >= 0.08 && rectangle.maxX <= 0.92
            let inVerticalRange = rectangle.minY >= 0.12 && rectangle.maxY <= 0.85
            return hasSize && inHorizontalRange && inVerticalRange
        }
        guard isInsideModal(a), isInsideModal(b) else { return nil }
        let vertical = abs(a.midX - b.midX) < 0.12 && abs(a.midY - b.midY) > 0.015 && abs(a.midY - b.midY) < 0.2
        let horizontal = abs(a.midY - b.midY) < 0.035 && abs(a.midX - b.midX) > 0.12 && abs(a.midX - b.midX) < 0.6
        guard vertical || horizontal else { return nil }
        let buttonTop = max(a.maxY, b.maxY)
        let body = regions.filter {
            $0.confidence >= 0.65 && $0.bounds.midY > buttonTop &&
            $0.bounds.midY - buttonTop < 0.35 && $0.bounds.midX > 0.12 && $0.bounds.midX < 0.88
        }.sorted {
            abs($0.bounds.midY - $1.bounds.midY) < 0.015 ? $0.bounds.minX < $1.bounds.minX : $0.bounds.midY > $1.bounds.midY
        }.map { normalized($0.text) }.joined()
        let intent = body.range(of: "想(?:要)?(?:从.{0,80})?粘贴", options: .regularExpression) != nil ||
            body.range(of: "想(?:要)?(?:從.{0,80})?貼上", options: .regularExpression) != nil || body.contains("wouldliketopaste")
        let question = body.contains("允许此操作") || body.contains("允許此操作") ||
            body.contains("允许这样做") || body.contains("允許這樣做") ||
            body.contains("doyouwanttoallowthis") || body.contains("wouldyouliketoallowthis")
        guard intent && question else { return nil }
        return DeviceCore.NormalizedPoint(x: a.midX, y: 1 - a.midY)
    }
}
