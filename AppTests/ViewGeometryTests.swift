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
