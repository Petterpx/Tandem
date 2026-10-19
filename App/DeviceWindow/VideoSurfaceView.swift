import AppKit
import SwiftUI
import CoreVideo
import IOSurface
import DeviceCore

final class VideoSurfaceView: NSView, @preconcurrency NSTextInputClient {
    var onInput: ((InputAction) -> Void)?
    var onPaste: (() -> Void)?

    private(set) var videoSize: CGSize = .zero
    private var markedText = NSMutableAttributedString()
    /// 本次拖动是否从视频区域内开始。
    private var dragActive = false
    private var scrollGesture = ScrollGesture()
    /// 触摸板双指拖动的起点（视图坐标）；nil 表示当前没有在模拟拖动。
    private var scrollDragStart: CGPoint?
    /// 上一次按其比例调整过窗口的视频尺寸。
    private var sizedForVideo: CGSize?
    private let aspect = WindowAspectController()
    /// 是否按视频比例调整所在窗口：弹出窗口为 true；工作台里由 SwiftUI 布局缩放画面，不能动窗口。
    /// 也决定出现时是否接管键盘焦点（只有弹出窗口）。
    var sizesWindow = true
    /// 工作台外框里为 true：图层按外框内圆角裁切，输入换算不受影响（仍按 bounds）。
    var roundsCorners = false {
        didSet { if roundsCorners != oldValue { needsLayout = true } }
    }

    /// 由窗口视图在收到 .running(w,h) 时设置。
    var runningSize: CGSize? {
        didSet { applyWindowGeometry() }
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(Theme.videoBackground).cgColor
        layer?.contentsGravity = .resizeAspect
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = roundsCorners ? BezelGeometry.innerRadius(screenWidth: bounds.width) : 0
        layer?.masksToBounds = roundsCorners
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyWindowGeometry()
        // 只有弹出窗口一出现就接管键盘；工作台里要等点击画面（mouseDown）才接管，
        // 否则侧栏方向键、剪贴板输入框会被新出现的画面抢走焦点。
        if sizesWindow { window?.makeFirstResponder(self) }
    }

    /// 首次 running 时把窗口设为屏幕可见高度的 80%；之后视频比例变化（旋转）时保持视频区域的长边、
    /// 按新比例重设窗口，并保证不超出屏幕可见区域。拖动调整大小由 WindowAspectController 约束。
    private func applyWindowGeometry() {
        guard sizesWindow, let window, let size = runningSize, size.width > 0, size.height > 0 else { return }
        aspect.attach(to: window)
        aspect.videoSize = size
        if let previous = sizedForVideo, abs(previous.width / previous.height - size.width / size.height) < 0.01 { return }
        let isFirst = sizedForVideo == nil
        sizedForVideo = size

        let bar = WindowAspectController.nonVideoHeight(of: window)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let chrome = window.frameRect(forContentRect: .zero).size  // 内容区以外的窗口装饰（全尺寸内容视图时为 0）
        let maxContent = CGSize(width: visible.width - chrome.width, height: visible.height - chrome.height)
        let current = window.contentRect(forFrameRect: window.frame).size
        let longEdge = isFirst ? visible.height * 0.8 - bar : max(current.width, current.height - bar)
        let content = ViewGeometry.contentSize(video: size, longEdge: longEdge, barHeight: bar, fitting: maxContent)

        // 保持左上角不动，再挪进屏幕可见区域。
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    // MARK: 渲染

    func show(_ frame: VideoFrame) {
        let pb = frame.pixelBuffer
        videoSize = CGSize(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb))
        layer?.contents = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue()
    }

    // MARK: 鼠标

    private func point(_ event: NSEvent, clamp: Bool) -> NormalizedPoint? {
        ViewGeometry.normalizedPoint(convert(event.locationInWindow, from: nil), viewSize: bounds.size, videoSize: videoSize, clamp: clamp)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let p = point(event, clamp: false) else { dragActive = false; return }
        // 双指拖动还没抬起时点击：先结束它，两者共用同一个手指 id。
        if scrollDragStart != nil {
            scrollDragStart = nil
            onInput?(.touch(.up, p))
        }
        dragActive = true
        onInput?(.touch(.down, p))
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragActive, let p = point(event, clamp: true) else { return }
        onInput?(.touch(.move, p))
    }

    override func mouseUp(with event: NSEvent) {
        guard dragActive, let p = point(event, clamp: true) else { return }
        dragActive = false
        onInput?(.touch(.up, p))
    }

    override func rightMouseDown(with event: NSEvent) {
        onInput?(.key(.back))
    }

    override func scrollWheel(with event: NSEvent) {
        let outputs = scrollGesture.handle(deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
                                           precise: event.hasPreciseScrollingDeltas,
                                           phase: event.phase, momentumPhase: event.momentumPhase)
        let location = convert(event.locationInWindow, from: nil)
        for output in outputs {
            switch output {
            case let .wheel(dx, dy):
                guard let p = point(event, clamp: false) else { continue }
                onInput?(.scroll(p, dx: dx, dy: dy))
            case let .touch(phase, offset):
                if phase == .down {
                    // 手势从黑边或鼠标拖动中开始时整段忽略。
                    let inside = ViewGeometry.normalizedPoint(location, viewSize: bounds.size, videoSize: videoSize, clamp: false) != nil
                    scrollDragStart = inside && !dragActive ? location : nil
                }
                guard let start = scrollDragStart else { continue }
                let current = CGPoint(x: start.x + offset.dx, y: start.y + offset.dy)
                guard let p = ViewGeometry.normalizedPoint(current, viewSize: bounds.size, videoSize: videoSize, clamp: true) else { continue }
                onInput?(.touch(phase, p))
                if phase == .up { scrollDragStart = nil }
            }
        }
    }

    // MARK: 键盘

    override func keyDown(with event: NSEvent) {
        // 输入法组字期间，所有按键（含 Esc/方向键/回车）先交给输入法。
        if !hasMarkedText(), let cmd = KeyMapping.command(keyCode: event.keyCode, modifiers: event.modifierFlags) {
            dispatch(cmd)
            return
        }
        interpretKeyEvents([event])
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, !hasMarkedText(),
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
              let cmd = KeyMapping.command(keyCode: event.keyCode, modifiers: event.modifierFlags) else { return false }
        dispatch(cmd)
        return true
    }

    private func dispatch(_ cmd: KeyCommand) {
        switch cmd {
        case .input(let action): onInput?(action)
        case .pasteFromMac: onPaste?()
        }
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        markedText = NSMutableAttributedString()
        let text = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        guard !text.isEmpty else { return }
        onInput?(.text(text))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if let a = string as? NSAttributedString {
            markedText = NSMutableAttributedString(attributedString: a)
        } else if let s = string as? String {
            markedText = NSMutableAttributedString(string: s)
        }
    }

    func unmarkText() { markedText = NSMutableAttributedString() }
    func hasMarkedText() -> Bool { markedText.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: markedText.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { 0 }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // 候选窗贴在视图底部中间。
        let local = NSRect(x: bounds.midX, y: bounds.maxY, width: 0, height: 0)
        guard let window else { return .zero }
        return window.convertToScreen(convert(local, to: nil))
    }

    override func doCommand(by selector: Selector) {
        // 未映射的命令（如 moveToBeginningOfLine:）忽略，避免系统提示音。
    }
}
