import DeviceCore
import Foundation
import Testing
@testable import Tandem

@Suite struct PastePermissionResolverTests {
    private func region(_ text: String, x: Double = 0.32, y: Double, width: Double = 0.36,
                        confidence: Float = 0.99) -> PastePermissionResolver.TextRegion {
        .init(text: text, bounds: CGRect(x: x, y: y, width: width, height: 0.025), confidence: confidence)
    }
    private var chinese: [PastePermissionResolver.TextRegion] {
        [region("“微信”想要从“设置”粘贴", y: 0.60), region("你允许此操作吗？", y: 0.55),
         region("不允许粘贴", y: 0.49), region("允许粘贴", y: 0.43)]
    }

    @Test func recognizesChineseSystemDialogAndConvertsVisionCoordinates() throws {
        let point = try #require(PastePermissionResolver.button(in: chinese))
        #expect(abs(point.x - 0.5) < 0.0001)
        #expect(abs(point.y - (1 - 0.4425)) < 0.0001)
    }

    @Test func recognizesObservedSettingsPasteboardSystemWording() {
        let regions = [region("“设置”想从“dtpasteboardd”粘贴", y: 0.60),
                       region("你允许这样做吗？", y: 0.55),
                       region("允许粘贴", x: 0.22, y: 0.43, width: 0.18),
                       region("不允许粘贴", x: 0.58, y: 0.43, width: 0.20)]
        let point = PastePermissionResolver.button(in: regions)
        #expect(point != nil)
        #expect(abs((point?.x ?? 0) - 0.31) < 0.0001)
    }

    @Test func recognizesEnglishSystemDialog() {
        let regions = [region("WeChat Would Like to Paste from Settings", y: 0.60),
                       region("Do you want to allow this?", y: 0.55),
                       region("Don't Allow", y: 0.49), region("Allow Paste", y: 0.43)]
        #expect(PastePermissionResolver.button(in: regions) != nil)
    }

    @Test func ignoresPasteKeywordWithoutSystemDialog() {
        let regions = [region("教程：允许粘贴来输入搜索内容", y: 0.60),
                       region("不允许粘贴", y: 0.49), region("允许粘贴", y: 0.43)]
        #expect(PastePermissionResolver.button(in: regions) == nil)
    }

    @Test func requiresIntentQuestionAndBothExactButtons() {
        for missing in chinese.indices {
            var regions = chinese
            regions.remove(at: missing)
            #expect(PastePermissionResolver.button(in: regions) == nil)
        }
        var substring = chinese
        substring[3] = region("点击允许粘贴", y: 0.43)
        #expect(PastePermissionResolver.button(in: substring) == nil)
    }

    @Test func ambiguousOrLowConfidenceButtonsAreIgnored() {
        var duplicate = chinese
        duplicate.append(region("允许粘贴", x: 0.1, y: 0.2, confidence: 0.4))
        #expect(PastePermissionResolver.button(in: duplicate) == nil)
        var faint = chinese
        faint[3] = region("允许粘贴", y: 0.43, confidence: 0.6)
        #expect(PastePermissionResolver.button(in: faint) == nil)
    }

    @Test func requiresDialogGeometryAndBodyAboveButtons() {
        var separated = chinese
        separated[3] = region("允许粘贴", y: 0.15)
        #expect(PastePermissionResolver.button(in: separated) == nil)
        let inverted = [region("微信想要粘贴", y: 0.2), region("你允许此操作吗？", y: 0.15),
                        region("不允许粘贴", y: 0.49), region("允许粘贴", y: 0.43)]
        #expect(PastePermissionResolver.button(in: inverted) == nil)
    }
}
