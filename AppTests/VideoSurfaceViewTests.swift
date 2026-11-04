import AppKit
import Testing
import DeviceCore
@testable import Tandem

@MainActor
@Suite struct VideoSurfaceViewTests {
    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        return window
    }

    @Test func workspaceSurfaceDoesNotTakeFocusOnAppear() {
        let window = makeWindow()
        let surface = VideoSurfaceView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        surface.sizesWindow = false
        window.contentView?.addSubview(surface)
        #expect(window.firstResponder !== surface)
    }

    @Test func popupSurfaceTakesFocusOnAppear() {
        let window = makeWindow()
        let surface = VideoSurfaceView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        surface.sizesWindow = true
        window.contentView?.addSubview(surface)
        #expect(window.firstResponder === surface)
    }

    @Test(arguments: [true, false]) func endingSurfaceInteractionReleasesHeldTouch(detach: Bool) throws {
        let window = makeWindow()
        let surface = VideoSurfaceView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        surface.sizesWindow = false
        surface.platform = .ios
        window.contentView?.addSubview(surface)
        surface.show(FakeDeviceSession.makeFrame(size: CGSize(width: 100, height: 100), pts: .zero))
        var inputs: [InputAction] = []
        surface.onInput = { inputs.append($0) }
        let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
            location: surface.convert(CGPoint(x: 25, y: 30), to: nil),
            modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        surface.mouseDown(with: event)
        #expect(inputs == [.touch(.down, .init(x: 0.25, y: 0.3))])
        if detach { surface.removeFromSuperview() }
        else { _ = window.makeFirstResponder(window.contentView) }
        #expect(inputs == [
            .touch(.down, .init(x: 0.25, y: 0.3)),
            .touch(.up, .init(x: 0.25, y: 0.3)),
        ])
    }

    @Test func iosRightClickDoesNotEmitBack() throws {
        let surface = VideoSurfaceView(frame: .zero)
        surface.platform = .ios
        var inputs: [InputAction] = []
        surface.onInput = { inputs.append($0) }
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1))
        surface.rightMouseDown(with: event)
        #expect(inputs.isEmpty)
        surface.platform = .android
        surface.rightMouseDown(with: event)
        #expect(inputs == [.key(.back)])
    }

    @Test func iosShortcutDispatchKeepsHomeAndPaste() throws {
        let window = makeWindow()
        let surface = VideoSurfaceView(frame: .zero)
        surface.platform = .ios
        window.contentView?.addSubview(surface)
        window.makeFirstResponder(surface)
        var inputs: [InputAction] = []
        var pasted = false
        surface.onInput = { inputs.append($0) }
        surface.onPaste = { pasted = true }
        func key(_ code: UInt16, _ character: String) throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: .command, timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: character, charactersIgnoringModifiers: character,
                isARepeat: false, keyCode: code))
        }
        #expect(!surface.performKeyEquivalent(with: try key(1, "s")))
        #expect(surface.performKeyEquivalent(with: try key(4, "h")))
        #expect(surface.performKeyEquivalent(with: try key(9, "v")))
        #expect(inputs == [.key(.home)])
        #expect(pasted)
    }

    @Test func iosPhaseLessPreciseBurstUsesOneTouchUntilIdle() async throws {
        let window = makeWindow()
        let surface = makeScrollingSurface(in: window)
        var inputs: [InputAction] = []
        surface.onInput = { inputs.append($0) }
        let start = ProcessInfo.processInfo.systemUptime
        for index in 0..<60 {
            surface.scrollWheel(with: wheel(on: surface, dy: -1, timestamp: start + Double(index) / 60))
        }
        #expect(inputs.filter { if case .scroll = $0 { true } else { false } }.isEmpty)
        #expect(inputs.filter { if case .touch(.down, _, _) = $0 { true } else { false } }.count == 1)
        #expect(inputs.last == .touch(.move, .init(x: 0.5, y: 0.2)))
        #expect(inputs.filter { if case .touch(.up, _, _) = $0 { true } else { false } }.isEmpty)
        try await Task.sleep(for: .milliseconds(180))
        #expect(inputs.last == .touch(.up, .init(x: 0.5, y: 0.2)))
        #expect(inputs.filter { if case .touch(.up, _, _) = $0 { true } else { false } }.count == 1)
    }

    @Test func phaseLessSourceGapStartsNewTouchAndOldTimerCannotReleaseIt() async throws {
        let window = makeWindow()
        let surface = makeScrollingSurface(in: window)
        var inputs: [InputAction] = []
        surface.onInput = { inputs.append($0) }
        let start = ProcessInfo.processInfo.systemUptime
        surface.scrollWheel(with: wheel(on: surface, dy: -8, timestamp: start))
        try await Task.sleep(for: .milliseconds(40))
        surface.scrollWheel(with: wheel(on: surface, dy: -8, timestamp: start + 0.2))
        #expect(inputs == [
            .touch(.down, .init(x: 0.5, y: 0.8)), .touch(.move, .init(x: 0.5, y: 0.72)),
            .touch(.up, .init(x: 0.5, y: 0.72)),
            .touch(.down, .init(x: 0.5, y: 0.8)), .touch(.move, .init(x: 0.5, y: 0.72)),
        ])
        try await Task.sleep(for: .milliseconds(50))
        #expect(inputs.filter { if case .touch(.up, _, _) = $0 { true } else { false } }.count == 1)
        try await Task.sleep(for: .milliseconds(100))
        #expect(inputs.last == .touch(.up, .init(x: 0.5, y: 0.72)))
        #expect(inputs.filter { if case .touch(.up, _, _) = $0 { true } else { false } }.count == 2)
    }

    @Test func iosTrackpadDeliversMotionCarriedByBeganEvent() {
        let window = makeWindow()
        let surface = makeScrollingSurface(in: window)
        var inputs: [InputAction] = []
        surface.onInput = { inputs.append($0) }
        surface.scrollWheel(with: wheel(on: surface, dy: -8, phase: .began))
        #expect(inputs == [
            .touch(.down, .init(x: 0.5, y: 0.8)),
            .touch(.move, .init(x: 0.5, y: 0.72)),
        ], "A source began event can carry the first movement; it must not wait for another event")
        surface.scrollWheel(with: wheel(on: surface, dy: 0, phase: .ended))
        #expect(inputs.last == .touch(.up, .init(x: 0.5, y: 0.72)),
            "A short began/ended gesture must still drag and release")
    }

    @Test func iosTinyTrackpadGestureNeverBecomesTap() {
        let window = makeWindow()
        let surface = makeScrollingSurface(in: window)
        var inputs: [InputAction] = []
        surface.onInput = { inputs.append($0) }
        surface.scrollWheel(with: wheel(on: surface, dy: -0.25, phase: .began))
        surface.scrollWheel(with: wheel(on: surface, dy: -0.25, phase: .changed))
        surface.scrollWheel(with: wheel(on: surface, dy: 0, phase: .ended))
        #expect(inputs.isEmpty, "A tiny two-finger gesture over a button must not become a tap")
    }

    @Test func iosTrackpadReverseRespondsImmediatelyAfterReachingScreenEdge() throws {
        let window = makeWindow()
        let surface = makeScrollingSurface(in: window)
        var inputs: [InputAction] = []
        surface.onInput = { inputs.append($0) }
        surface.scrollWheel(with: wheel(on: surface, dy: 0, phase: .began))
        for _ in 0..<30 {
            surface.scrollWheel(with: wheel(on: surface, dy: -5, phase: .changed))
        }
        let before = try #require(inputs.last)
        surface.scrollWheel(with: wheel(on: surface, dy: 5, phase: .changed))
        let after = try #require(inputs.last)
        guard case let .touch(.move, previous, _) = before,
              case let .touch(.move, reversed, _) = after else {
            Issue.record("Both directions must deliver touch movement")
            return
        }
        #expect(reversed.y > previous.y,
            "Reversing fingers must move content immediately without unwinding offscreen overshoot")
        surface.scrollWheel(with: wheel(on: surface, dy: 0, phase: .ended))
    }

    private enum ScrollBoundary: CaseIterable { case key, text, paste, mouse, phased, momentum, focus, detach, mouseWheel }

    @Test(arguments: ScrollBoundary.allCases)
    private func phaseLessTouchReleasesBeforeNextInteraction(_ boundary: ScrollBoundary) async throws {
        let window = makeWindow()
        let surface = makeScrollingSurface(in: window)
        _ = window.makeFirstResponder(surface)
        var inputs: [InputAction] = []
        surface.onInput = { inputs.append($0) }
        surface.onPaste = { inputs.append(.text("PASTE")) }
        surface.scrollWheel(with: wheel(on: surface, dy: -8, timestamp: ProcessInfo.processInfo.systemUptime))
        switch boundary {
        case .key, .paste:
            let paste = boundary == .paste
            let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: paste ? .command : [], timestamp: 1, windowNumber: window.windowNumber,
                context: nil, characters: paste ? "v" : "\r", charactersIgnoringModifiers: paste ? "v" : "\r",
                isARepeat: false, keyCode: paste ? 9 : 36))
            if paste { #expect(surface.performKeyEquivalent(with: event)) }
            else { surface.keyDown(with: event) }
        case .text:
            surface.insertText("a", replacementRange: NSRange(location: NSNotFound, length: 0))
        case .mouse:
            let event = try #require(NSEvent.mouseEvent(with: .leftMouseDown,
                location: surface.convert(CGPoint(x: 25, y: 30), to: nil), modifierFlags: [],
                timestamp: 1, windowNumber: window.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1))
            surface.mouseDown(with: event)
        case .phased:
            surface.scrollWheel(with: wheel(on: surface, dy: 0, phase: .began))
            surface.scrollWheel(with: wheel(on: surface, dy: -8, phase: .changed))
        case .momentum:
            surface.scrollWheel(with: wheel(on: surface, dy: -20, momentum: .began))
        case .focus: _ = window.makeFirstResponder(window.contentView)
        case .detach: surface.removeFromSuperview()
        case .mouseWheel:
            surface.scrollWheel(with: wheel(on: surface, dy: -1, precise: false))
        }
        #expect(inputs.count >= 3)
        #expect(inputs.prefix(3) == [
            .touch(.down, .init(x: 0.5, y: 0.8)), .touch(.move, .init(x: 0.5, y: 0.72)),
            .touch(.up, .init(x: 0.5, y: 0.72)),
        ])
        let count = inputs.count
        try await Task.sleep(for: .milliseconds(180))
        #expect(inputs.count == count, "The previous idle timer must not end the next interaction")
        // Finish held mouse/phased interactions owned by this test.
        _ = window.makeFirstResponder(window.contentView)
    }

    @Test(arguments: [Platform.android, .ios])
    func nonPreciseMouseWheelKeepsWheelSemantics(_ platform: Platform) {
        let window = makeWindow()
        let surface = makeScrollingSurface(in: window)
        surface.platform = platform
        var inputs: [InputAction] = []
        surface.onInput = { inputs.append($0) }
        surface.scrollWheel(with: wheel(on: surface, dy: -2, precise: false))
        #expect(inputs == [.scroll(.init(x: 0.5, y: 0.8), dx: 0, dy: -2)])
        if platform == .android {
            surface.scrollWheel(with: wheel(on: surface, dy: -10))
            #expect(inputs.last == .scroll(.init(x: 0.5, y: 0.8), dx: 0, dy: -1))
        }
    }

    private func makeScrollingSurface(in window: NSWindow) -> VideoSurfaceView {
        let surface = VideoSurfaceView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        surface.platform = .ios
        surface.sizesWindow = false
        window.contentView?.addSubview(surface)
        surface.show(FakeDeviceSession.makeFrame(size: CGSize(width: 100, height: 100), pts: .zero))
        return surface
    }

    private func wheel(on surface: VideoSurfaceView, dy: CGFloat, precise: Bool = true,
                       phase: NSEvent.Phase = [], momentum: NSEvent.Phase = [],
                       timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> NSEvent {
        SurfaceScrollEvent(location: surface.convert(CGPoint(x: 50, y: 80), to: nil), dy: dy,
            precise: precise, phase: phase, momentum: momentum, timestamp: timestamp)
    }
}

private final class SurfaceScrollEvent: NSEvent, @unchecked Sendable {
    private let location: CGPoint
    private let delta: CGFloat
    private let precise: Bool
    private let sourcePhase: NSEvent.Phase
    private let inertiaPhase: NSEvent.Phase
    private let sourceTime: TimeInterval
    init(location: CGPoint, dy: CGFloat, precise: Bool, phase: NSEvent.Phase,
         momentum: NSEvent.Phase, timestamp: TimeInterval) {
        self.location = location
        delta = dy
        self.precise = precise
        sourcePhase = phase
        inertiaPhase = momentum
        sourceTime = timestamp
        super.init()
    }
    required init?(coder: NSCoder) { fatalError("Not used") }
    override var locationInWindow: NSPoint { location }
    override var scrollingDeltaX: CGFloat { 0 }
    override var scrollingDeltaY: CGFloat { delta }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var phase: NSEvent.Phase { sourcePhase }
    override var momentumPhase: NSEvent.Phase { inertiaPhase }
    override var timestamp: TimeInterval { sourceTime }
}
