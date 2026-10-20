import SwiftUI

enum ChipTone { case accent, neutral, ai, success, danger, count }

/// 小号胶囊标签；`dot` 前置一个圆点。
struct Chip: View {
    let text: String
    let tone: ChipTone
    let dot: Bool

    init(_ text: String, tone: ChipTone, dot: Bool = false) {
        self.text = text
        self.tone = tone
        self.dot = dot
    }

    private var large: Bool { dot || tone == .count }

    private var colors: (fill: Color, text: Color, dot: Color) {
        switch tone {
        case .accent: (Theme.accentTint, Theme.accentStrong, Theme.accentStrong)
        case .neutral: (Theme.chipNeutral, Theme.textTertiary, Theme.textTertiary)
        case .ai: (Theme.aiTint, Theme.aiText, Theme.aiText)
        case .success: (Theme.successTint, Theme.successText, Theme.success)
        case .danger: (Theme.danger.opacity(0.12), Theme.danger, Theme.danger)
        case .count: (Theme.chipCount, Theme.textTertiary, Theme.textTertiary)
        }
    }

    var body: some View {
        let colors = colors
        HStack(spacing: 4) {
            if dot { Circle().fill(colors.dot).frame(width: 6, height: 6) }
            Text(text)
        }
        .font(.system(size: large ? 11 : 10))
        .foregroundStyle(colors.text)
        .padding(.vertical, large ? (tone == .count ? 0 : 2) : 1)
        .padding(.horizontal, large ? (tone == .count ? 7 : 8) : 6)
        .background(RoundedRectangle(cornerRadius: large ? 9 : Metrics.chipRadius).fill(colors.fill))
    }
}

/// 状态圆点：实心或 1.5 px 空心描边。
struct StatusDot: View {
    var size: CGFloat = 6
    var filled: Bool = true
    var color: Color = Theme.success

    var body: some View {
        Group {
            if filled {
                Circle().fill(color)
            } else {
                Circle().strokeBorder(Theme.dotOff, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
    }
}
