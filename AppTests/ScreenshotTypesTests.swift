import AppKit
import Testing
@testable import Tandem

@Suite struct ScreenshotTypesTests {
    @Test func qualityFromModifiers() {
        #expect(ScreenshotQuality(modifiers: [.option]) == .lossless)
        #expect(ScreenshotQuality(modifiers: [.option, .shift]) == .lossless)
        #expect(ScreenshotQuality(modifiers: []) == .standard)
        #expect(ScreenshotQuality.lossless.logTitle == "高清截图" && ScreenshotQuality.standard.logTitle == "截图")
    }

    @Test func noteText() {
        #expect(ScreenshotText.note(width: 1080, height: 2400, source: .mirrorFrame) == "1080×2400 · 投屏画质 · 已复制到剪贴板")
        #expect(ScreenshotText.note(width: nil, height: nil, source: .screencap) == "无损 · 已复制到剪贴板")
    }
}
