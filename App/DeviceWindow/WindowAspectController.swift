import AppKit

/// 让设备窗口的视频区域（内容减去底栏）保持视频比例。
///
/// `contentAspectRatio` 只能约束整个内容区，而内容区还包含固定高度的底栏，所以改为在
/// `windowWillResize(_:to:)` 里约束。SwiftUI 自己持有窗口的 delegate，这里插入一层代理：
/// 只处理 `windowWillResize`（先交给 SwiftUI 的实现），其余消息原样转发给原 delegate。
@MainActor
final class WindowAspectController: NSObject, NSWindowDelegate {
    /// 当前视频尺寸（像素）；nil 时不约束。
    var videoSize: CGSize?

    /// 原 delegate（SwiftUI 的）。NSWindow.delegate 本身是弱引用，这里同样弱引用。
    nonisolated(unsafe) private weak var inner: NSWindowDelegate?
    /// 本次拖动开始时的内容尺寸：每一步都和它比较，判断用户主要在拖哪条边。
    private var liveResizeStart: CGSize?
    private weak var observedWindow: NSWindow?
    /// 只在主线程读写；deinit 里移除观察者。
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// 内容区里不属于视频的高度：底栏，加上被标题栏盖住的部分（SwiftUI 窗口的内容延伸到标题栏下面）。
    static func nonVideoHeight(of window: NSWindow) -> CGFloat {
        let content = window.contentRect(forFrameRect: window.frame)
        return ViewGeometry.bottomBarHeight + max(0, content.height - window.contentLayoutRect.height)
    }

    /// 插到窗口的 delegate 前面；可重复调用（SwiftUI 换了 delegate 时重新插入）。
    func attach(to window: NSWindow) {
        observeLiveResize(of: window)
        guard window.delegate !== self else { return }
        inner = window.delegate
        window.delegate = self
    }

    /// 用通知而不是 delegate 方法记录拖动起点，不影响 SwiftUI 自己的 delegate 回调。
    private func observeLiveResize(of window: NSWindow) {
        guard observedWindow !== window else { return }
        observers.forEach(NotificationCenter.default.removeObserver)
        observedWindow = window
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: NSWindow.willStartLiveResizeNotification, object: window, queue: .main) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let window else { return }
                    self?.liveResizeStart = window.contentRect(forFrameRect: window.frame).size
                }
            },
            center.addObserver(forName: NSWindow.didEndLiveResizeNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.liveResizeStart = nil }
            },
        ]
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let proposedFrame = inner?.windowWillResize?(sender, to: frameSize) ?? frameSize
        guard let videoSize else { return proposedFrame }
        let start = liveResizeStart ?? sender.contentRect(forFrameRect: sender.frame).size
        let proposed = sender.contentRect(forFrameRect: NSRect(origin: .zero, size: proposedFrame)).size
        let content = ViewGeometry.constrainedContentSize(proposed: proposed, start: start, video: videoSize,
                                                          barHeight: Self.nonVideoHeight(of: sender))
        return sender.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
    }

    // MARK: 转发

    override func responds(to aSelector: Selector!) -> Bool {
        super.responds(to: aSelector) || (inner?.responds(to: aSelector) ?? false)
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if let inner, inner.responds(to: aSelector) { return inner }
        return super.forwardingTarget(for: aSelector)
    }
}
