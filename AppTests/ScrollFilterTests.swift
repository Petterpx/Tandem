import AppKit
import Testing
@testable import Tandem

struct ScrollFilterTests {
    @Test func mouseWheelPassesThroughWithHorizontalFlipped() {
        var f = ScrollFilter()
        let out = f.filter(dx: 1, dy: -2, phase: [], momentumPhase: [])
        #expect(out?.dx == -1)
        #expect(out?.dy == -2)
    }

    @Test func verticalGestureDropsHorizontalJitter() {
        var f = ScrollFilter()
        #expect(f.filter(dx: 0, dy: 0, phase: .began, momentumPhase: []) == nil)
        // 判定前累积，未过阈值不下发
        #expect(f.filter(dx: 0.1, dy: -0.2, phase: .changed, momentumPhase: []) == nil)
        let first = f.filter(dx: 0.1, dy: -0.3, phase: .changed, momentumPhase: [])
        #expect(first?.dx == 0)
        #expect(first?.dy == -0.5)
        let next = f.filter(dx: 0.3, dy: -1, phase: .changed, momentumPhase: [])
        #expect(next?.dx == 0)
        #expect(next?.dy == -1)
        // 惯性阶段沿用同一方向
        let momentum = f.filter(dx: 0.2, dy: -0.4, phase: [], momentumPhase: .changed)
        #expect(momentum?.dx == 0)
        #expect(momentum?.dy == -0.4)
    }

    @Test func horizontalGestureIsFlippedAndDropsVerticalJitter() {
        var f = ScrollFilter()
        _ = f.filter(dx: 0, dy: 0, phase: .began, momentumPhase: [])
        let first = f.filter(dx: -0.6, dy: 0.1, phase: .changed, momentumPhase: [])
        #expect(first?.dx == 0.6)
        #expect(first?.dy == 0)
        let next = f.filter(dx: -1, dy: -0.5, phase: .changed, momentumPhase: [])
        #expect(next?.dx == 1)
        #expect(next?.dy == 0)
    }

    @Test func newGestureDecidesAxisAgain() {
        var f = ScrollFilter()
        _ = f.filter(dx: 0, dy: 0, phase: .began, momentumPhase: [])
        _ = f.filter(dx: 0, dy: -1, phase: .changed, momentumPhase: [])
        _ = f.filter(dx: 0, dy: 0, phase: .began, momentumPhase: [])
        let out = f.filter(dx: 1, dy: 0, phase: .changed, momentumPhase: [])
        #expect(out?.dx == -1)
        #expect(out?.dy == 0)
    }

    @Test func momentumWithoutDecisionDecidesImmediately() {
        var f = ScrollFilter()
        _ = f.filter(dx: 0, dy: 0, phase: .began, momentumPhase: [])
        #expect(f.filter(dx: 0, dy: -0.1, phase: .changed, momentumPhase: []) == nil)
        let out = f.filter(dx: 0, dy: -0.1, phase: [], momentumPhase: .began)
        #expect(out?.dx == 0)
        #expect(out?.dy == -0.2)
    }
}
