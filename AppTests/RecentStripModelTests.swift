import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Tandem

/// 假的 Quick Look：记录调用，toggle 切换可见。
@MainActor
private final class FakeQuickLook {
    var visible = false
    var toggles: [(urls: [URL], index: Int)] = []
    var selects: [Int] = []
    var closes = 0
    var onMove: ((Int) -> Void)?

    /// 强引用 self：测试里丢弃了 fake 时 hooks 仍可用。
    var hooks: QuickLookHooks {
        QuickLookHooks(
            toggle: { urls, index, onMove in
                self.toggles.append((urls, index))
                self.onMove = onMove
                self.visible.toggle()
            },
            select: { self.selects.append($0) },
            close: {
                if self.visible { self.closes += 1 }
                self.visible = false
            },
            isVisible: { self.visible })
    }

    /// 所有发给面板的 URL。
    var sentURLs: [URL] { toggles.flatMap(\.urls) }
}

@MainActor
@Suite struct RecentStripModelTests {
    /// recent 依次为 c、b（文件已删除）、a。
    private func makeEnv() async throws -> (RecentStripModel, FakeQuickLook, MacPasteboard, a: CaptureItem, b: CaptureItem, c: CaptureItem) {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let pb = MacPasteboard(NSPasteboard(name: .init(UUID().uuidString)))
        let store = CaptureStore(pasteboard: pb, defaults: UserDefaults(suiteName: UUID().uuidString)!, home: home)
        let png = AIEnv.png(width: 10, height: 20)
        let a = try await store.saveScreenshot(.png(png), deviceName: "A").item
        let b = try await store.saveScreenshot(.png(png), deviceName: "B").item
        let c = try await store.saveScreenshot(.png(png), deviceName: "C").item
        try FileManager.default.removeItem(at: b.url)
        let fake = FakeQuickLook()
        return (RecentStripModel(store: store, quickLook: fake.hooks), fake, pb, a, b, c)
    }

    @Test func spaceSendsOnlyExistingFilesWithMappedIndex() async throws {
        let (model, fake, _, a, _, c) = try await makeEnv()
        model.select(a.id)
        #expect(model.space() == .handled)
        #expect(fake.toggles.count == 1)
        #expect(fake.toggles.first?.urls == [c.url, a.url] && fake.toggles.first?.index == 1)
        // 再按空格关闭
        #expect(model.space() == .handled && !fake.visible)
    }

    @Test func spaceOnUnselectedOrDeletedIsHandledWithoutPreview() async throws {
        let (model, fake, _, _, b, _) = try await makeEnv()
        #expect(model.space() == .handled)
        model.select(b.id)
        #expect(model.space() == .handled)
        #expect(fake.toggles.isEmpty)
    }

    @Test func selectWhileVisibleFollowsAndSkipsDeleted() async throws {
        let (model, fake, _, a, b, c) = try await makeEnv()
        model.select(c.id)
        _ = model.space()
        model.select(a.id)
        #expect(fake.selects == [1])
        // 选中已删除的磁贴：预览停在原处
        model.select(b.id)
        #expect(fake.selects == [1] && fake.visible)
        #expect(!fake.sentURLs.contains(b.url))
    }

    @Test func moveWhileVisibleFollowsAndSkipsDeleted() async throws {
        let (model, fake, _, a, b, c) = try await makeEnv()
        model.select(c.id)
        _ = model.space()
        #expect(model.move(1) == .handled && model.selectedID == b.id)
        #expect(fake.selects.isEmpty)
        _ = model.move(1)
        #expect(model.selectedID == a.id && fake.selects == [1])
        _ = model.move(1)
        #expect(model.selectedID == a.id)
        // 面板为 key 时，← / → 经 onMove 回来
        fake.onMove?(-1)
        fake.onMove?(-1)
        #expect(model.selectedID == c.id && fake.selects == [1, 1, 0])
    }

    @Test func moveWhileHiddenDoesNotTouchPanel() async throws {
        let (model, fake, _, _, _, c) = try await makeEnv()
        _ = model.move(1)
        #expect(model.selectedID == c.id)
        #expect(fake.selects.isEmpty && fake.toggles.isEmpty)
    }

    @Test func escapeClosesPanelThenClearsSelection() async throws {
        let (model, fake, _, a, _, _) = try await makeEnv()
        model.select(a.id)
        _ = model.space()
        #expect(model.escape() == .handled && fake.closes == 1 && model.selectedID == a.id)
        #expect(model.escape() == .handled && model.selectedID == nil)
        // 无选中时也算处理过，不发出提示音
        #expect(model.escape() == .handled)
    }

    @Test func listChangeClosesPanelAndDropsRemovedSelection() async throws {
        let (model, fake, _, a, _, c) = try await makeEnv()
        model.select(a.id)
        _ = model.space()
        model.store.remove(c)
        model.listChanged()
        #expect(fake.closes == 1 && model.selectedID == a.id)
        model.store.remove(a)
        model.listChanged()
        #expect(model.selectedID == nil)
    }

    @Test func copyOnlyExistingSelection() async throws {
        let (model, _, pb, a, b, _) = try await makeEnv()
        let before = pb.changeCount
        model.select(b.id)
        model.copy()
        #expect(pb.changeCount == before)
        model.select(a.id)
        model.copy()
        #expect((pb.pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL]) == [a.url])
    }
}
