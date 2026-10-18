import CoreGraphics

/// 固定画布的布局计算（纯函数）。
public enum CanvasLayout {
    /// 画布尺寸取首帧尺寸，宽、高各自向下取偶数（H.264 要求偶数宽高）。
    public static func canvasSize(for first: CGSize) -> CGSize {
        CGSize(width: evenFloor(first.width), height: evenFloor(first.height))
    }

    /// 内容等比缩放后放进画布居中的矩形；原点在左下（与 CoreImage 一致）。
    public static func fit(_ content: CGSize, in canvas: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return .zero }
        let scale = min(canvas.width / content.width, canvas.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (canvas.width - size.width) / 2, y: (canvas.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    private static func evenFloor(_ value: CGFloat) -> CGFloat {
        CGFloat(Int(value) / 2 * 2)
    }
}
