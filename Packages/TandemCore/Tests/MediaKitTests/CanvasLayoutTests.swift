import CoreGraphics
import Testing
@testable import MediaKit

struct CanvasLayoutTests {
    @Test func landscapeContentInPortraitCanvasIsCenteredAndScaled() {
        let r = CanvasLayout.fit(CGSize(width: 1920, height: 908), in: CGSize(width: 908, height: 1920))
        #expect(r.width == 908)
        #expect(abs(r.height - 908 * 908 / 1920) < 0.5)
        #expect(abs(r.midY - 960) < 0.5 && r.minX == 0)
    }

    @Test func sameSizeFillsCanvas() {
        #expect(CanvasLayout.fit(CGSize(width: 908, height: 1920), in: CGSize(width: 908, height: 1920))
                == CGRect(x: 0, y: 0, width: 908, height: 1920))
    }

    @Test func canvasSizeIsEven() {
        #expect(CanvasLayout.canvasSize(for: CGSize(width: 909, height: 1921)) == CGSize(width: 908, height: 1920))
    }
}
