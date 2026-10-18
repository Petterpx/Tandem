import Testing
@testable import Tandem

/// spec §3 会话规则表，每个用例对应一行。
@Suite struct MirrorSetTests {
    private func workspace() -> MirrorSet {
        var m = MirrorSet()
        m.setWorkspaceOpen(true)
        return m
    }

    @Test func firstSelectKeepsDevice() {
        var m = workspace()
        m.select("a")
        #expect(m.wanted == ["a"])
    }

    @Test func switchingKeepsPrevious() {
        var m = workspace()
        m.select("a")
        m.select("b")
        #expect(m.wanted == ["a", "b"])
    }

    @Test func popOutAddsAndClosingKeepsIfKept() {
        var m = workspace()
        m.select("a")
        m.popOut("a")
        #expect(m.wanted == ["a"])
        m.popupClosed("a")
        #expect(m.wanted == ["a"])
        // 只弹出、没在工作台选中过的设备：关闭弹出窗口后不再运行
        m.popOut("b")
        #expect(m.wanted == ["a", "b"])
        m.popupClosed("b")
        #expect(!m.wanted.contains("b"))
    }

    @Test func stopMirroringDropsUnlessPopped() {
        var m = workspace()
        m.select("a")
        m.stopMirroring("a")
        #expect(m.wanted == [])
        m.select("b")
        m.popOut("b")
        m.stopMirroring("b")
        #expect(m.wanted == ["b"])
        // 再次选中时重新加入
        m.select("a")
        #expect(m.wanted == ["a", "b"])
    }

    @Test func removeDropsEverywhere() {
        var m = workspace()
        m.select("a")
        m.popOut("a")
        m.remove("a")
        #expect(m.wanted == [])
        #expect(m.kept.isEmpty && m.popped.isEmpty)
    }

    @Test func closingWorkspaceStopsOnlyNonPopped() {
        var m = workspace()
        m.select("a")
        m.select("b")
        m.popOut("b")
        m.setWorkspaceOpen(false)
        #expect(m.wanted == ["b"])
        #expect(m.kept == ["a", "b"])
        m.setWorkspaceOpen(true)
        #expect(m.wanted == ["a", "b"])
    }
}
