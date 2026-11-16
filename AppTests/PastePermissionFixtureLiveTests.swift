import CoreImage
import CoreVideo
import DeviceCore
import Foundation
import ImageIO
import Testing
@testable import Tandem

/// Local OCR only. The caller supplies a private screenshot path; no fixture is
/// committed, no image leaves this process and no device action is executed.
@Suite struct PastePermissionFixtureLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TANDEN_PASTE_FIXTURE_PATH"]?.isEmpty == false))
    func recognizesRealSystemPasteDialogWithinBudget() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["TANDEN_PASTE_FIXTURE_PATH"])
        let source = try #require(CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var output: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
                                        kCVPixelFormatType_32BGRA, nil, &output)
        try #require(status == kCVReturnSuccess)
        let buffer = try #require(output)
        CIContext().render(CIImage(cgImage: image), to: buffer)
        let start = ContinuousClock.now
        let point = try #require(await PastePermissionResolver.resolve(VideoFrame(pixelBuffer: buffer)))
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(1500))
        #expect((0.27...0.35).contains(point.x))
        #expect((0.53...0.61).contains(point.y))
        print("Paste permission fixture: \(elapsed), point=(\(point.x),\(point.y))")
    }
}
