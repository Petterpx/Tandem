import Foundation
import Observation
import SwiftUI

/// 截图条的按键逻辑（纯值类型）：选中、空格预览、⌘C 拷贝、← / → 切换、Esc 取消。
struct RecentStripKeys {
    enum KeyAction: Equatable {
        case none
        /// 预览该项；下标是它在 `previewURLs`（只含文件还在的项）里的位置。
        case preview(URL, Int)
        case copy(CaptureItem)
    }

    private(set) var items: [CaptureItem]
    var selectedID: UUID?
    /// 文件已删除的项：可以选中，但空格与 ⌘C 不做事，也不交给 Quick Look。
    var missingIDs: Set<UUID>

    init(items: [CaptureItem], selectedID: UUID?, missingIDs: Set<UUID> = []) {
        self.items = items
        self.selectedID = selectedID
        self.missingIDs = missingIDs
    }

    var selectedIndex: Int? {
        selectedID.flatMap { id in items.firstIndex { $0.id == id } }
    }

    /// 交给预览面板的列表：跳过文件已删除的项。
    var previewURLs: [URL] {
        items.filter { !missingIDs.contains($0.id) }.map(\.url)
    }

    /// `id` 在 `previewURLs` 里的位置；文件已删除或不在列表里时为 nil。
    func previewIndex(of id: UUID?) -> Int? {
        guard let id, !missingIDs.contains(id) else { return nil }
        return items.filter { !missingIDs.contains($0.id) }.firstIndex { $0.id == id }
    }

    /// 选中且文件还在的项。
    private var available: CaptureItem? {
        guard let index = selectedIndex, !missingIDs.contains(items[index].id) else { return nil }
        return items[index]
    }

    func space() -> KeyAction {
        guard let item = available, let index = previewIndex(of: item.id) else { return .none }
        return .preview(item.url, index)
    }

    func copy() -> KeyAction {
        available.map { .copy($0) } ?? .none
    }

    mutating func move(_ step: Int) {
        selectedID = AppPolicy.adjacentID(items.map(\.id), from: selectedID, step: step)
    }

    mutating func escape() {
        selectedID = nil
    }

    /// 列表变化后，选中项不在了就清空选中。
    mutating func update(items: [CaptureItem]) {
        self.items = items
        if selectedIndex == nil { selectedID = nil }
    }
}

/// 截图条调用 Quick Look 的入口，可换成假实现。
struct QuickLookHooks {
    /// 已打开则关闭，否则预览第 index 项；面板里按 ← / → 时回调 onMove(∓1 / ±1)。
    var toggle: @MainActor (_ urls: [URL], _ index: Int, _ onMove: @escaping (Int) -> Void) -> Void
    var select: @MainActor (_ index: Int) -> Void
    var close: @MainActor () -> Void
    var isVisible: @MainActor () -> Bool

    @MainActor static var live: QuickLookHooks {
        let controller = QuickLookController.shared
        return QuickLookHooks(
            toggle: { urls, index, onMove in
                controller.onMove = onMove
                controller.toggle(urls: urls, index: index)
            },
            select: { controller.select(index: $0) },
            close: { controller.close() },
            isVisible: { controller.isVisible })
    }
}

/// 截图条的选中与按键：把 `RecentStripKeys` 的结果接到存储与 Quick Look 上。
/// 截图条有焦点时按键一律算处理过（不发出提示音），只是没有可做的事时什么也不做。
@MainActor @Observable
final class RecentStripModel {
    let store: CaptureStore
    @ObservationIgnored private let quickLook: QuickLookHooks
    private(set) var selectedID: UUID?

    init(store: CaptureStore, quickLook: QuickLookHooks = .live) {
        self.store = store
        self.quickLook = quickLook
    }

    private var keys: RecentStripKeys {
        RecentStripKeys(
            items: store.recent, selectedID: selectedID,
            missingIDs: Set(store.recent.filter { !store.fileExists($0) }.map(\.id)))
    }

    /// 单击磁贴。面板开着时跟着切换；选中文件已删除的项时预览停在原处。
    func select(_ id: UUID) {
        selectedID = id
        syncPanel()
    }

    /// 空格：面板开着就关闭，否则预览选中项（只交给面板文件还在的项）。
    func space() -> KeyPress.Result {
        if quickLook.isVisible() {
            quickLook.close()
        } else if case .preview(_, let index) = keys.space() {
            quickLook.toggle(keys.previewURLs, index) { [weak self] step in _ = self?.move(step) }
        }
        return .handled
    }

    func move(_ step: Int) -> KeyPress.Result {
        var k = keys
        k.move(step)
        guard let id = k.selectedID else { return .ignored }
        selectedID = id
        syncPanel()
        return .handled
    }

    /// Esc：面板开着就关闭，否则取消选中。
    func escape() -> KeyPress.Result {
        if quickLook.isVisible() {
            quickLook.close()
        } else {
            selectedID = nil
        }
        return .handled
    }

    /// ⌘C：行为同「拷贝」；文件已删除时不做事。
    func copy() {
        if case .copy(let item) = keys.copy() { store.copy(item) }
    }

    /// 列表变了，面板里的下标就不再对应，先关掉；选中项被移除时清空选中。
    func listChanged() {
        quickLook.close()
        var k = keys
        k.update(items: store.recent)
        selectedID = k.selectedID
    }

    private func syncPanel() {
        guard quickLook.isVisible(), let index = keys.previewIndex(of: selectedID) else { return }
        quickLook.select(index)
    }
}
