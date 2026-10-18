import CoreGraphics
import DeviceCore

enum ViewGeometry {
    /// 视频在视图内等比居中后的矩形（原点左上）。
    static func videoRect(viewSize: CGSize, videoSize: CGSize) -> CGRect {
        guard viewSize.width > 0, viewSize.height > 0, videoSize.width > 0, videoSize.height > 0 else { return .zero }
        let scale = min(viewSize.width / videoSize.width, viewSize.height / videoSize.height)
        let w = videoSize.width * scale
        let h = videoSize.height * scale
        return CGRect(x: (viewSize.width - w) / 2, y: (viewSize.height - h) / 2, width: w, height: h)
    }

    /// p 以视图左上为原点。clamp=false 时落在黑边返回 nil；clamp=true 时夹到 0...1。
    static func normalizedPoint(_ p: CGPoint, viewSize: CGSize, videoSize: CGSize, clamp: Bool) -> NormalizedPoint? {
        let rect = videoRect(viewSize: viewSize, videoSize: videoSize)
        guard rect.width > 0, rect.height > 0 else { return nil }
        if !clamp && !rect.contains(p) { return nil }
        let x = min(max((p.x - rect.minX) / rect.width, 0), 1)
        let y = min(max((p.y - rect.minY) / rect.height, 0), 1)
        return NormalizedPoint(x: Double(x), y: Double(y))
    }
}
