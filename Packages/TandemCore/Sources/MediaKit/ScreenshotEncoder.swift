import CoreImage
import CoreVideo
import DeviceCore
import Foundation
import ImageIO

/// 把截图缩放到 AI 坐标空间（长边 1280）并编码。
public enum ScreenshotEncoder {
    public struct Output: Sendable, Equatable {
        public let data: Data
        public let mimeType: String
        public let width: Int
        public let height: Int
    }

    private static let invalid = DeviceError(code: .CONNECTION_FAILED, message: "截图数据无效")
    /// 共用一个 CIContext（创建开销大，且可跨线程使用），不在每次截图时新建。
    private static let context = CIContext()

    /// 视频帧 → JPEG（质量 0.8）。
    public static func encodeFrame(_ pixelBuffer: CVPixelBuffer) throws -> Output {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { throw invalid }
        return try encode(cgImage, type: "public.jpeg", mimeType: "image/jpeg", quality: 0.8)
    }

    /// 视频帧 → 原尺寸 PNG（用于保存到文件，不缩放）。
    public static func encodeFramePNG(_ pixelBuffer: CVPixelBuffer) throws -> Output {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { throw invalid }
        guard let data = pngData(cgImage) else { throw invalid }
        return Output(data: data, mimeType: "image/png", width: cgImage.width, height: cgImage.height)
    }

    /// PNG → 长边不超过 `maxSide` 的缩略 PNG；数据无效返回 nil，原图较小时不放大。
    public static func thumbnailPNG(_ png: Data, maxSide: Int = 256) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let size = pixelSize(of: source)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // 缩略图接口会把小图放大到 maxPixelSize，所以上限取原图长边
            kCGImageSourceThumbnailMaxPixelSize: min(maxSide, max(size.width, size.height)),
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return pngData(thumb)
    }

    /// 只读 PNG 头部得到像素尺寸，不解码整图；数据无效返回 nil。
    public static func pixelSize(ofPNG png: Data) -> (width: Int, height: Int)? {
        CGImageSourceCreateWithData(png as CFData, nil).flatMap { pixelSize(of: $0) }
    }

    private static func pixelSize(of source: CGImageSource) -> (width: Int, height: Int)? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (w, h)
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }

    /// PNG 数据 → 缩放后的 PNG。
    public static func encodePNG(_ png: Data) throws -> Output {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw invalid }
        return try encode(cgImage, type: "public.png", mimeType: "image/png", quality: nil)
    }

    private static func encode(_ image: CGImage, type: String, mimeType: String, quality: Double?) throws -> Output {
        guard let space = CoordinateSpace(screenWidth: Double(image.width), screenHeight: Double(image.height)),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: nil, width: space.width, height: space.height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw invalid }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: space.width, height: space.height))
        guard let scaled = context.makeImage() else { throw invalid }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { throw invalid }
        let options = quality.map { [kCGImageDestinationLossyCompressionQuality: $0] as CFDictionary }
        CGImageDestinationAddImage(destination, scaled, options)
        guard CGImageDestinationFinalize(destination) else { throw invalid }
        return Output(data: data as Data, mimeType: mimeType, width: space.width, height: space.height)
    }
}
