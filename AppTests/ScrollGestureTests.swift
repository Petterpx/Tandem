import AppKit
import Testing
import DeviceCore
@testable import Tandem

struct ScrollGestureTests {
    private func step(_ g: inout ScrollGesture, _ dx: CGFloat, _ dy: CGFloat,
                      phase: NSEvent.Phase = .changed, momentum: NSEvent.Phase = []) -> [ScrollGesture.Output] {
        g.handle(deltaX: dx, deltaY: dy, precise: true, phase: phase, momentumPhase: momentum)
    }

    @Test func mouseWheelBecomesScrollWithHorizontalFlipped() {
        var g = ScrollGesture()
        #expect(g.handle(deltaX: 1, deltaY: -2, precise: false, phase: [], momentumPhase: []) == [.wheel(dx: -1, dy: -2)])
        // 无 phase 的精确滚动（部分鼠标）同样走滚轮，并按 10 缩小
        #expect(g.handle(deltaX: 10, deltaY: 20, precise: true, phase: [], momentumPhase: []) == [.wheel(dx: -1, dy: 2)])
    }

    @Test func verticalSwipeBecomesAxisLockedDrag() {
        var g = ScrollGesture()
        #expect(step(&g, 0, 0, phase: .began).isEmpty)
        #expect(step(&g, 1, -2).isEmpty)  // 未过阈值
        #expect(step(&g, 1, -3) == [.touch(.down, offset: .zero), .touch(.move, offset: CGVector(dx: 0, dy: -5))])
        #expect(step(&g, 3, -10) == [.touch(.move, offset: CGVector(dx: 0, dy: -15))])
        #expect(step(&g, 0, 0, phase: .ended) == [.touch(.up, offset: CGVector(dx: 0, dy: -15))])
    }

    @Test func horizontalSwipeFollowsFingers() {
        var g = ScrollGesture()
        _ = step(&g, 0, 0, phase: .began)
        #expect(step(&g, -6, 1) == [.touch(.down, offset: .zero), .touch(.move, offset: CGVector(dx: -6, dy: 0))])
        #expect(step(&g, -10, -4) == [.touch(.move, offset: CGVector(dx: -16, dy: 0))])
    }

    @Test func momentumIsIgnored() {
        var g = ScrollGesture()
        _ = step(&g, 0, 0, phase: .began)
        _ = step(&g, 0, -8)
        _ = step(&g, 0, 0, phase: .ended)
        #expect(step(&g, 0, -30, phase: [], momentum: .began).isEmpty)
        #expect(step(&g, 0, -20, phase: [], momentum: .changed).isEmpty)
        #expect(step(&g, 0, 0, phase: [], momentum: .ended).isEmpty)
    }

    @Test func tinyGestureSendsNothingSoItNeverTaps() {
        var g = ScrollGesture()
        _ = step(&g, 0, 0, phase: .mayBegin)
        _ = step(&g, 0, 0, phase: .began)
        #expect(step(&g, 1, 1).isEmpty)
        #expect(step(&g, 0, 0, phase: .ended).isEmpty)
        #expect(step(&g, 0, 0, phase: .cancelled).isEmpty)
    }

    @Test func newGestureDecidesAxisAgain() {
        var g = ScrollGesture()
        _ = step(&g, 0, 0, phase: .began)
        _ = step(&g, 0, -8)
        _ = step(&g, 0, 0, phase: .ended)
        _ = step(&g, 0, 0, phase: .began)
        #expect(step(&g, 8, 0) == [.touch(.down, offset: .zero), .touch(.move, offset: CGVector(dx: 8, dy: 0))])
    }

    @Test func beganWhileDraggingEndsPreviousDrag() {
        var g = ScrollGesture()
        _ = step(&g, 0, 0, phase: .began)
        _ = step(&g, 0, -8)
        #expect(step(&g, 0, 0, phase: .began) == [.touch(.up, offset: CGVector(dx: 0, dy: -8))])
    }
}
