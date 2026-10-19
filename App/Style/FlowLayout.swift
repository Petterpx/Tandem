import SwiftUI

/// 自动换行的横向排布。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    /// 贪心换行：返回每行的子视图下标；比 `maxWidth` 还宽的项独占一行。
    static func rows(widths: [CGFloat], maxWidth: CGFloat, spacing: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var used: CGFloat = 0
        for (index, width) in widths.enumerated() {
            if !current.isEmpty, used + spacing + width > maxWidth {
                rows.append(current)
                current = []
                used = 0
            }
            used += current.isEmpty ? width : spacing + width
            current.append(index)
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    private func layout(_ subviews: Subviews, maxWidth: CGFloat) -> (frames: [CGRect], size: CGSize) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = Self.rows(widths: sizes.map(\.width), maxWidth: maxWidth, spacing: spacing)
        var frames = [CGRect](repeating: .zero, count: sizes.count)
        var y: CGFloat = 0
        var totalWidth: CGFloat = 0
        for (rowIndex, row) in rows.enumerated() {
            var x: CGFloat = 0
            var rowHeight: CGFloat = 0
            for index in row {
                frames[index] = CGRect(origin: CGPoint(x: x, y: y), size: sizes[index])
                x += sizes[index].width + spacing
                rowHeight = max(rowHeight, sizes[index].height)
            }
            totalWidth = max(totalWidth, x - spacing)
            y += rowHeight + (rowIndex < rows.count - 1 ? lineSpacing : 0)
        }
        return (frames, CGSize(width: totalWidth, height: y))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(subviews, maxWidth: proposal.width ?? .infinity).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews, maxWidth: bounds.width)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }
}
