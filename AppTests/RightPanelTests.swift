import DeviceCore
import Testing
@testable import Tandem

@MainActor
@Suite struct RightPanelTests {
    @Test func androidShowsSupportedSectionsInOrderWithoutDeveloperSection() {
        #expect(QuickSectionID.visible(capabilities: Set(Capability.allCases)) == [.network, .apps, .openURL, .system, .custom])
        // 保留内部枚举与能力映射，供模型、MCP 和既有存储使用。
        #expect(QuickSectionID.devOptions.capability == .devOptions)
    }

    @Test func simulatorShowsOnlyOpenURL() {
        #expect(QuickSectionID.visible(capabilities: [.openURL, .clipboard]) == [.openURL])
    }

    @Test func physicalIPhoneHasNoQuickSections() {
        #expect(QuickSectionID.visible(capabilities: [.mirror, .touch, .keys, .screenshot, .record]).isEmpty)
        #expect(QuickSectionID.visible(capabilities: [.devOptions]).isEmpty)
        #expect(QuickSectionID.visible(capabilities: []).isEmpty)
    }

    @Test func tabTitles() {
        #expect(RightTab.quickActions.title == "快捷操作" && RightTab.ai.title == "AI")
        #expect(RightTab.files.title == "文件" && RightTab.clipboard.title == "剪贴板")
    }
}
