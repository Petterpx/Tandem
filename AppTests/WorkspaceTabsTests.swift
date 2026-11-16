import DeviceCore
import Testing
@testable import Tandem

@MainActor
@Suite struct WorkspaceTabsTests {
    @Test func tabsFollowDeviceCapabilities() {
        #expect(RightTab.visible(capabilities: Set(Capability.allCases)) == [.quickActions, .files, .clipboard, .ai])
        #expect(RightTab.visible(capabilities: [.openURL, .clipboard]) == [.quickActions, .clipboard, .ai])
        #expect(RightTab.visible(capabilities: [.mirror, .touch, .keys, .screenshot, .record]) == [.ai])
        #expect(RightTab.visible(capabilities: [.files]) == [.files, .ai])
        #expect(RightTab.visible(capabilities: [.clipboard]) == [.clipboard, .ai])
        #expect(RightTab.visible(capabilities: [.devOptions]) == [.ai])
        #expect(RightTab.visible(capabilities: []) == [.ai])
    }

    @Test func deviceSwitchFallsBackFromUnsupportedTab() {
        let tabs = WorkspaceTabs()
        tabs.selected = .files
        // Android 文件页切到模拟器，回落到该设备第一个可用标签。
        tabs.selected = RightTab.resolvedSelection(tabs.selected, capabilities: [.openURL, .clipboard])
        #expect(tabs.selected == .quickActions)
        // 切到仅支持投屏的 USB iPhone，再切回 Android，始终保留合法选择。
        tabs.selected = RightTab.resolvedSelection(tabs.selected, capabilities: [.mirror, .touch, .keys, .screenshot, .record])
        #expect(tabs.selected == .ai)
        #expect(RightTab.resolvedSelection(tabs.selected, capabilities: Set(Capability.allCases)) == .ai)
        #expect(RightTab.resolvedSelection(.clipboard, capabilities: []) == .ai)
        #expect(RightTab.resolvedSelection(.files, capabilities: [.clipboard]) == .clipboard)
        #expect(RightTab.resolvedSelection(.clipboard, capabilities: [.clipboard]) == .clipboard)
    }

    @Test func clipboardCopy() {
        #expect(ClipboardTab.syncSubtitle(on: true) == "已开启：Mac 与手机剪贴板实时同步")
        #expect(ClipboardTab.syncSubtitle(on: false) == "默认关闭，需要时手动读取或写入")
        #expect(ClipboardDirection.read.chipTone == .accent && ClipboardDirection.write.chipTone == .neutral)
        #expect(ClipboardDirection.sync.chipTone == .neutral)
        #expect(ClipboardDirection.read.chipTitle == "读" && ClipboardDirection.write.chipTitle == "写")
        #expect(ClipboardDirection.sync.chipTitle == "同步")
    }

    @Test func aiLockCopy() {
        #expect(AITab.lockSubtitle(locked: true) == "已禁止 AI 操控此设备")
        #expect(AITab.lockSubtitle(locked: false) == "开启后，AI 无法操控此设备")
    }
}
