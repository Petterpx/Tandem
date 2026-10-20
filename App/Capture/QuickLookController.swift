import AppKit
import Quartz

/// Quick Look 预览面板的接线（最近截图条按空格）。
/// 面板沿响应链寻找控制者，所以打开时把自己插到当前窗口之后、关闭时摘掉；
/// 面板成为 key 时它自己收到 ←/→ / 空格，转给 `onMove` 或直接关闭。
@MainActor final class QuickLookController: NSResponder, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookController()

    private var urls: [URL] = []
    private var index = 0
    private weak var hostWindow: NSWindow?
    /// 面板里按 ← / → 时回调（-1 / +1），由视图切换选中后再调 `select`。
    var onMove: ((Int) -> Void)?

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
    }

    /// 已打开则关闭；否则预览 `urls[index]`。
    func toggle(urls: [URL], index: Int) {
        if isVisible {
            close()
            return
        }
        guard urls.indices.contains(index), let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        self.index = index
        attach()
        panel.updateController()
        panel.reloadData()
        panel.currentPreviewItemIndex = index
        // 不抢 key：焦点留在截图条，空格、← / →、Esc 仍由截图条处理
        panel.orderFront(nil)
    }

    /// 面板开着时切换到第 `index` 项。
    func select(index: Int) {
        guard isVisible, urls.indices.contains(index) else { return }
        self.index = index
        QLPreviewPanel.shared().currentPreviewItemIndex = index
    }

    func close() {
        guard isVisible else { return }
        QLPreviewPanel.shared().orderOut(nil)
    }

    // MARK: 响应链

    private func attach() {
        guard hostWindow == nil, let window = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        nextResponder = window.nextResponder
        window.nextResponder = self
        hostWindow = window
    }

    private func detach() {
        guard let window = hostWindow else { return }
        if window.nextResponder === self { window.nextResponder = nextResponder }
        nextResponder = nil
        hostWindow = nil
    }

    // QLPreviewPanelController 是 NSObject 上的非隔离分类方法，面板总在主线程调用。
    nonisolated override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    nonisolated override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.delegate = self
        }
    }

    nonisolated override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = nil
            panel.delegate = nil
            detach()
        }
    }

    // MARK: 数据源与代理

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        let url = MainActor.assumeIsolated { urls.indices.contains(index) ? urls[index] : nil }
        return url.map { $0 as NSURL }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown else { return false }
        let keyCode = event.keyCode
        return MainActor.assumeIsolated {
            switch keyCode {
            case 123: onMove?(-1)  // ←
            case 124: onMove?(1)  // →
            case 49: close()  // 空格
            default: return false
            }
            return true
        }
    }
}
