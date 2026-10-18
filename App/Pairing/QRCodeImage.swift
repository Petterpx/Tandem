import AppKit
import CoreImage.CIFilterBuiltins

/// 配对二维码图片：四周至少 4 个模块的白色静区，按整数倍放大（配合 .interpolation(.none) 保持边缘锐利）。
struct QRCodeImage {
    let cgImage: CGImage
    /// 每个模块的像素边长。
    let moduleSize: Int

    var nsImage: NSImage { NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)) }

    /// CIQRCodeGenerator 自带 1 个模块的白边，再补 3 个凑足规范要求的 4 个。
    private static let extraQuietModules: CGFloat = 3
    private static let context = CIContext()

    static func make(for text: String, targetWidth: Int) -> QRCodeImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let pad = extraQuietModules
        let canvas = CGRect(x: 0, y: 0, width: output.extent.width + 2 * pad, height: output.extent.height + 2 * pad)
        let padded = output
            .transformed(by: CGAffineTransform(translationX: pad - output.extent.minX, y: pad - output.extent.minY))
            .composited(over: CIImage(color: .white).cropped(to: canvas))
        let scale = max(1, Int(CGFloat(targetWidth) / canvas.width))
        let scaled = padded.transformed(by: CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return QRCodeImage(cgImage: cg, moduleSize: scale)
    }
}
