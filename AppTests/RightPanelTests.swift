import Testing
@testable import Tandem

@MainActor
@Suite struct RightPanelTests {
    @Test func sectionOrderFollowsDesign() {
        #expect(QuickSectionID.allCases == [.network, .apps, .openURL, .system, .devOptions, .custom])
    }

    @Test func visibleTabsDependOnFiles() {
        #expect(RightTab.visible(hasFiles: true) == [.quickActions, .files, .clipboard, .ai])
        #expect(RightTab.visible(hasFiles: false) == [.quickActions, .clipboard, .ai])
        #expect(RightTab.quickActions.title == "快捷操作" && RightTab.ai.title == "AI")
        #expect(RightTab.files.title == "文件" && RightTab.clipboard.title == "剪贴板")
    }

    @Test func overviewTitle() {
        #expect(CapabilityOverviewCard.title(deviceName: "Pixel 8") == "能力概览 · Pixel 8")
    }
}
