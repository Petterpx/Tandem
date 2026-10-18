import AppKit
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
    private var didSizeWindow = false

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
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyWindowGeometry()
        window?.makeFirstResponder(self)
    }

    private func applyWindowGeometry() {
        guard let window, let size = runningSize, size.width > 0, size.height > 0 else { return }
        window.contentAspectRatio = NSSize(width: size.width, height: size.height)
        guard !didSizeWindow else { return }
        didSizeWindow = true
        let screenHeight = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let h = screenHeight * 0.8
        window.setContentSize(NSSize(width: h * size.width / size.height, height: h))
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
        guard let p = point(event, clamp: false) else { return }
        let divisor: Double = event.hasPreciseScrollingDeltas ? 10 : 1
        let dx = Double(event.scrollingDeltaX) / divisor
        let dy = Double(event.scrollingDeltaY) / divisor
        guard dx != 0 || dy != 0 else { return }
        onInput?(.scroll(p, dx: dx, dy: dy))
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
