import CoreGraphics
import DeviceCore

enum ViewGeometry {
    /// 设备窗口底部导航栏的高度（视频区域 = 内容区减去它）。
    static let bottomBarHeight: CGFloat = 40

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

    // MARK: 窗口尺寸：内容 = 视频区域 + 底栏，比例只作用于视频区域。

    /// 视频区域长边为 `longEdge`、按 `video` 比例，下方再加 `barHeight`；整体等比缩小到不超过 `maxContent`。
    static func contentSize(video: CGSize, longEdge: CGFloat, barHeight: CGFloat, fitting maxContent: CGSize) -> CGSize {
        guard video.width > 0, video.height > 0 else { return .zero }
        var scale = longEdge / max(video.width, video.height)
        scale = min(scale, maxContent.width / video.width, max(maxContent.height - barHeight, 1) / video.height)
        return CGSize(width: (video.width * scale).rounded(), height: (video.height * scale).rounded() + barHeight)
    }

    /// 拖动调整大小时保持视频区域（内容减去底栏）的比例：相对开始拖动时的尺寸 `start`，
    /// 以变化更大的那条边为准推出另一条边。
    static func constrainedContentSize(proposed: CGSize, start: CGSize, video: CGSize, barHeight: CGFloat) -> CGSize {
        guard video.width > 0, video.height > 0 else { return proposed }
        if abs(proposed.width - start.width) >= abs(proposed.height - start.height) {
            return CGSize(width: proposed.width, height: (proposed.width * video.height / video.width).rounded() + barHeight)
        }
        let videoHeight = max(proposed.height - barHeight, 1)
        return CGSize(width: (videoHeight * video.width / video.height).rounded(), height: proposed.height)
    }
}
