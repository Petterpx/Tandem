import CoreGraphics
import CoreVideo
import DeviceCore
import Foundation
import ImageIO

struct SimulatorFrameDecoder {
    static func decode(_ message: SimulatorMessage) throws -> VideoFrame {
        guard let encoded = message.jpeg, let data = Data(base64Encoded: encoded),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0, image.width <= 8192, image.height <= 8192,
              message.width == image.width, message.height == image.height else {
            throw DeviceError(code: .CONNECTION_FAILED, message: "模拟器 JPEG 帧或尺寸无效")
        }
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
                                        kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer)
        guard result == kCVReturnSuccess, let pixelBuffer else { throw DeviceError(code: .CONNECTION_FAILED, message: "无法分配模拟器帧缓冲") }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw DeviceError(code: .CONNECTION_FAILED, message: "无法解码模拟器帧")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return VideoFrame(pixelBuffer: pixelBuffer)
    }
}
