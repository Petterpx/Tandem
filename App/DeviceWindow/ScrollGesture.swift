import AppKit
import DeviceCore

/// Mac 滚动事件 → 设备输入。
///
/// - 触摸板双指滑动（有 phase）模拟一根手指拖动：开头约 4pt 位移锁定主方向后按下，跟随移动，松手抬起；
///   松手后的惯性事件丢弃，由 Android 按抬手速度自己 fling。若逐个下发 ACTION_SCROLL，
///   桌面（Launcher3 PagedView）每个事件翻一页，一次横滑会连翻好几页。
/// - 鼠标滚轮（无 phase）仍发滚动事件：横向取反，与 scrcpy 一致（SDL 取 `-deltaX`，
///   Android AXIS_HSCROLL 正值为向右滚）；精确滚动按 10 缩小。
struct ScrollGesture {
    enum Output: Equatable {
        /// 滚动事件，Android 轴约定。
        case wheel(dx: Double, dy: Double)
        /// 模拟手指；offset 为相对手势起点的视图位移（点，y 向下）。
        case touch(TouchPhase, offset: CGVector)
    }

    enum Axis { case horizontal, vertical }

    /// 判定方向（并按下）前需要累积的位移，单位为点。
    static let decideThreshold: CGFloat = 4

    private var offset = CGVector.zero
    private(set) var axis: Axis?
    private var dragging = false

    /// deltaX / deltaY 取 `NSEvent.scrollingDeltaX/Y`：表示内容的移动方向，等同手指在屏幕上拖动的方向。
    mutating func handle(deltaX: CGFloat, deltaY: CGFloat, precise: Bool,
                         phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) -> [Output] {
        if phase.isEmpty && momentumPhase.isEmpty {
            let divisor: Double = precise ? 10 : 1
            guard deltaX != 0 || deltaY != 0 else { return [] }
            return [.wheel(dx: -Double(deltaX) / divisor, dy: Double(deltaY) / divisor)]
        }
        guard momentumPhase.isEmpty else { return [] }

        var out: [Output] = []
        if phase.contains(.began) || phase.contains(.mayBegin) {
            if dragging { out.append(.touch(.up, offset: locked)) }
            reset()
        }
        offset.dx += deltaX
        offset.dy += deltaY

        if phase.contains(.changed) {
            if dragging {
                out.append(.touch(.move, offset: locked))
            } else if max(abs(offset.dx), abs(offset.dy)) >= Self.decideThreshold {
                axis = abs(offset.dx) > abs(offset.dy) ? .horizontal : .vertical
                dragging = true
                out.append(.touch(.down, offset: .zero))
                out.append(.touch(.move, offset: locked))
            }
        }
        if phase.contains(.ended) || phase.contains(.cancelled) {
            if dragging { out.append(.touch(.up, offset: locked)) }
            reset()
        }
        return out
    }

    private var locked: CGVector {
        switch axis {
        case .horizontal: CGVector(dx: offset.dx, dy: 0)
        case .vertical: CGVector(dx: 0, dy: offset.dy)
        case nil: offset
        }
    }

    private mutating func reset() {
        offset = .zero
        axis = nil
        dragging = false
    }
}
