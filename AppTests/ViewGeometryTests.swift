import Testing
import CoreGraphics
import DeviceCore
@testable import MagicDevX

@Test func videoRectLetterboxes() {
    #expect(ViewGeometry.videoRect(viewSize: .init(width: 600, height: 800), videoSize: .init(width: 1080, height: 2400)) == CGRect(x: 120, y: 0, width: 360, height: 800))
}
@Test func letterboxPointIsNil() {
    #expect(ViewGeometry.normalizedPoint(.init(x: 50, y: 400), viewSize: .init(width: 600, height: 800), videoSize: .init(width: 1080, height: 2400), clamp: false) == nil)
}
@Test func centerMapsToHalf() {
    #expect(ViewGeometry.normalizedPoint(.init(x: 300, y: 400), viewSize: .init(width: 600, height: 800), videoSize: .init(width: 1080, height: 2400), clamp: false) == NormalizedPoint(x: 0.5, y: 0.5))
}
@Test func dragClampsToEdge() {
    #expect(ViewGeometry.normalizedPoint(.init(x: 590, y: 900), viewSize: .init(width: 600, height: 800), videoSize: .init(width: 1080, height: 2400), clamp: true) == NormalizedPoint(x: 1, y: 1))
}

// MARK: - 窗口尺寸（视频区域 + 底栏）

@Test func contentSizeKeepsLongEdgeOnRotation() {
    // 竖屏视频区域 400x888，转成横屏：长边 888 保持不变，底栏 40 加在下面。
    let size = ViewGeometry.contentSize(video: .init(width: 2400, height: 1080), longEdge: 888, barHeight: 40,
                                        fitting: .init(width: 2000, height: 1200))
    #expect(size == CGSize(width: 888, height: 400 + 40))
    let back = ViewGeometry.contentSize(video: .init(width: 1080, height: 2400), longEdge: 888, barHeight: 40,
                                        fitting: .init(width: 2000, height: 1200))
    #expect(back == CGSize(width: 400, height: 888 + 40))
}

@Test func contentSizeFitsTheScreen() {
    // 屏幕放不下：等比缩小视频区域，底栏高度不变。
    let tall = ViewGeometry.contentSize(video: .init(width: 1080, height: 2400), longEdge: 2400, barHeight: 40,
                                        fitting: .init(width: 1500, height: 940))
    #expect(tall == CGSize(width: 405, height: 900 + 40))
    let wide = ViewGeometry.contentSize(video: .init(width: 2400, height: 1080), longEdge: 2400, barHeight: 40,
                                        fitting: .init(width: 1200, height: 940))
    #expect(wide == CGSize(width: 1200, height: 540 + 40))
}

@Test func liveResizeKeepsVideoAreaRatio() {
    let video = CGSize(width: 1080, height: 2400)
    let start = CGSize(width: 400, height: 928)
    // 横向拖得多：以宽度为准
    #expect(ViewGeometry.constrainedContentSize(proposed: .init(width: 540, height: 930), start: start,
                                                video: video, barHeight: 40) == CGSize(width: 540, height: 1200 + 40))
    // 纵向拖得多：以高度为准
    #expect(ViewGeometry.constrainedContentSize(proposed: .init(width: 402, height: 520), start: start,
                                                video: video, barHeight: 40) == CGSize(width: 216, height: 520))
}

/// 实测：从 293x692 往下拖 150、往右 5。比较的基准必须是开始拖动时的尺寸——若和上一步约束后的尺寸比，
/// 宽度差会逐步累积，最后错误地按宽度计算（窗口几乎不变高）。
@Test func liveResizeComparesAgainstTheStartOfTheDrag() {
    let video = CGSize(width: 908, height: 1920)
    let size = ViewGeometry.constrainedContentSize(proposed: .init(width: 298, height: 842), start: .init(width: 293, height: 692),
                                                   video: video, barHeight: 72)
    #expect(size == CGSize(width: 364, height: 842))
}
