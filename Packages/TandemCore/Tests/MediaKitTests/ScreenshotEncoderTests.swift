import CoreGraphics
import CoreVideo
import DeviceCore
import Foundation
import ImageIO
import Testing
@testable import MediaKit

struct ScreenshotEncoderTests {
    private func size(of data: Data) throws -> (Int, Int) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }

    private func solidBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = try #require(status == kCVReturnSuccess ? buffer : nil)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        memset(CVPixelBufferGetBaseAddress(pixelBuffer), 0x80, CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }

    @Test func frameBecomesJPEGInSpace() throws {
        let output = try ScreenshotEncoder.encodeFrame(try solidBuffer(width: 64, height: 48))
        #expect(output.width == 1280 && output.height == 960)
        #expect(output.mimeType == "image/jpeg")
        let (w, h) = try size(of: output.data)
        #expect(w == 1280 && h == 960)
    }

    @Test func pngIsScaledDown() throws {
        let context = try #require(CGContext(
            data: nil, width: 1080, height: 2400, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1080, height: 2400))
        let image = try #require(context.makeImage())
        let png = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))

        let output = try ScreenshotEncoder.encodePNG(png as Data)
        #expect(output.width == 576 && output.height == 1280)
        #expect(output.mimeType == "image/png")
        let (w, h) = try size(of: output.data)
        #expect(w == 576 && h == 1280)
    }

    @Test func invalidPNGThrows() {
        #expect(throws: DeviceError.self) { try ScreenshotEncoder.encodePNG(Data([1, 2, 3])) }
    }
}
