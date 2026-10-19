import Testing
@testable import Tandem

@MainActor
@Suite struct WorkspaceTabsTests {
    @Test func clipboardCopy() {
        #expect(ClipboardTab.syncSubtitle(on: true) == "已开启：Mac 与手机剪贴板实时同步")
        #expect(ClipboardTab.syncSubtitle(on: false) == "默认关闭，需要时手动读取或写入")
        #expect(ClipboardDirection.read.chipTone == .accent && ClipboardDirection.write.chipTone == .neutral)
        #expect(ClipboardDirection.sync.chipTone == .neutral)
        #expect(ClipboardDirection.read.chipTitle == "读" && ClipboardDirection.write.chipTitle == "写")
        #expect(ClipboardDirection.sync.chipTitle == "同步")
    }

    @Test func aiLockCopy() {
        #expect(AITab.lockSubtitle(locked: true) == "已锁定：操作类工具返回 AI_LOCKED")
        #expect(AITab.lockSubtitle(locked: false) == "锁定后截图、UI 树、日志仍可用")
    }
}
