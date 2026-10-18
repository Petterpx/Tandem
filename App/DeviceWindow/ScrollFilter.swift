import AppKit

/// Mac 滚动量 → 设备滚动量。
///
/// - 横向取反：与 scrcpy 一致（SDL 取 `-deltaX`），Android AXIS_HSCROLL 正值为向右滚，方向与 macOS deltaX 相反。
/// - 触摸板手势（含松手后的惯性）按开头约 4pt 的位移锁定主方向，之后只下发该方向的分量；
///   否则上下滑时夹带的横向分量会被横向翻页控件接住。普通鼠标滚轮（无 phase）不锁定。
struct ScrollFilter {
    struct Delta: Equatable {
        var dx: Double
        var dy: Double
    }

    enum Axis { case horizontal, vertical }

    /// 判定方向前需要累积的位移（已除以精度系数后的单位）。
    static let decideThreshold = 0.4

    private(set) var axis: Axis?
    private var pending = Delta(dx: 0, dy: 0)

    /// dx / dy 为 macOS 约定的 scrollingDelta（已除以精度系数）；返回 nil 表示本事件暂不下发。
    mutating func filter(dx: Double, dy: Double, phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) -> Delta? {
        if phase.isEmpty && momentumPhase.isEmpty {
            return Delta(dx: -dx, dy: dy)
        }
        if phase.contains(.began) || phase.contains(.mayBegin) {
            axis = nil
            pending = Delta(dx: 0, dy: 0)
        }
        var delta = Delta(dx: dx, dy: dy)
        if axis == nil {
            pending.dx += dx
            pending.dy += dy
            let inMomentum = !momentumPhase.isEmpty
            guard inMomentum || max(abs(pending.dx), abs(pending.dy)) >= Self.decideThreshold else { return nil }
            guard pending.dx != 0 || pending.dy != 0 else { return nil }
            axis = abs(pending.dx) > abs(pending.dy) ? .horizontal : .vertical
            delta = pending
        }
        switch axis {
        case .horizontal: delta.dy = 0
        case .vertical, nil: delta.dx = 0
        }
        guard delta.dx != 0 || delta.dy != 0 else { return nil }
        return Delta(dx: -delta.dx, dy: delta.dy)
    }
}
