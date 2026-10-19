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

    private func png(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let png = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(png, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return png as Data
    }

    @Test func frameBecomesJPEGInSpace() throws {
        let output = try ScreenshotEncoder.encodeFrame(try solidBuffer(width: 64, height: 48))
        #expect(output.width == 1280 && output.height == 960)
        #expect(output.mimeType == "image/jpeg")
        let (w, h) = try size(of: output.data)
        #expect(w == 1280 && h == 960)
    }

    @Test func pngIsScaledDown() throws {
        let png = try png(width: 1080, height: 2400)

        let output = try ScreenshotEncoder.encodePNG(png)
        #expect(output.width == 576 && output.height == 1280)
        #expect(output.mimeType == "image/png")
        let (w, h) = try size(of: output.data)
        #expect(w == 576 && h == 1280)
    }

    @Test func invalidPNGThrows() {
        #expect(throws: DeviceError.self) { try ScreenshotEncoder.encodePNG(Data([1, 2, 3])) }
    }

    @Test func framePNGKeepsNativeSize() throws {
        let out = try ScreenshotEncoder.encodeFramePNG(try solidBuffer(width: 64, height: 48))
        #expect(out.mimeType == "image/png" && out.width == 64 && out.height == 48)
        let (w, h) = try size(of: out.data)
        #expect(w == 64 && h == 48)
    }

    @Test func thumbnailFitsLongEdge() throws {
        let thumb = try #require(ScreenshotEncoder.thumbnailPNG(try png(width: 1080, height: 2400)))
        let (w, h) = try size(of: thumb)
        #expect(h == 256 && (115...116).contains(w))
    }

    @Test func thumbnailDoesNotUpscale() throws {
        let thumb = try #require(ScreenshotEncoder.thumbnailPNG(try png(width: 64, height: 48)))
        let (w, h) = try size(of: thumb)
        #expect(w == 64 && h == 48)
    }

    @Test func invalidDataHasNoThumbnailOrSize() {
        #expect(ScreenshotEncoder.thumbnailPNG(Data([1, 2, 3])) == nil)
        #expect(ScreenshotEncoder.pixelSize(ofPNG: Data([1, 2, 3])) == nil)
    }

    @Test func pixelSizeReadsHeader() throws {
        #expect(ScreenshotEncoder.pixelSize(ofPNG: try png(width: 1080, height: 2400)).map { [$0.width, $0.height] } == [1080, 2400])
    }
}
