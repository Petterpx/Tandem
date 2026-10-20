import SwiftUI

/// 工作台统一按钮样式：次要 / 主要 / 图标 / 链接四种。
struct TandemButtonStyle: ButtonStyle {
    enum Kind { case secondary, primary, icon, ghostIcon, link }

    let kind: Kind
    var height: CGFloat
    /// 图标按钮的宽度；默认与高度相同（正方形）。
    var width: CGFloat?
    var tint: Color?
    var radius: CGFloat

    init(
        _ kind: Kind, height: CGFloat = Metrics.buttonHeight, width: CGFloat? = nil, tint: Color? = nil,
        radius: CGFloat = Metrics.buttonRadius
    ) {
        self.kind = kind
        self.height = height
        self.width = width
        self.tint = tint
        self.radius = radius
    }

    /// 各状态下的底色、描边与文字色。
    static func colors(_ kind: Kind, hovered: Bool, pressed: Bool) -> (fill: Color, stroke: Color, text: Color) {
        switch kind {
        case .primary:
            let fill = (hovered || pressed) ? Theme.accentStrong : Theme.accent
            return (fill, .clear, Theme.knob)
        case .secondary, .icon:
            let fill = (hovered || pressed) ? Theme.controlHover : Theme.card
            return (fill, Theme.controlBorder, Theme.textPrimary)
        case .ghostIcon:
            return ((hovered || pressed) ? Theme.controlHover : .clear, .clear, Theme.textSecondary)
        case .link:
            return (.clear, .clear, Theme.accentStrong)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(style: self, configuration: configuration)
    }

    private struct StyledButton: View {
        let style: TandemButtonStyle
        let configuration: Configuration
        @State private var hovered = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            let colors = TandemButtonStyle.colors(style.kind, hovered: hovered, pressed: configuration.isPressed)
            let shape = RoundedRectangle(cornerRadius: style.radius)
            Group {
                switch style.kind {
                case .link:
                    configuration.label
                        .font(.system(size: 12))
                        .foregroundStyle(style.tint ?? colors.text)
                        .opacity(hovered ? 0.8 : 1)
                case .icon:
                    configuration.label
                        .tandemText(.button)
                        .foregroundStyle(colors.text)
                        .frame(width: style.width ?? style.height, height: style.height)
                        .background(shape.fill(colors.fill))
                        .overlay(shape.strokeBorder(colors.stroke, lineWidth: 1))
                case .ghostIcon:
                    // 无底无边的次要图标，悬停时才出现底色
                    configuration.label
                        .foregroundStyle(colors.text)
                        .frame(width: style.width ?? style.height, height: style.height)
                        .background(shape.fill(colors.fill))
                case .secondary, .primary:
                    configuration.label
                        .labelStyle(TandemLabelStyle())
                        .tandemText(.button)
                        .foregroundStyle(colors.text)
                        .padding(.horizontal, 12)
                        .frame(height: style.height)
                        .background(shape.fill(colors.fill))
                        .overlay(shape.strokeBorder(colors.stroke, lineWidth: 1))
                }
            }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovered = $0 }
        }
    }
}

/// 按钮里的「图标 + 文字」：间距 6，对齐设计稿 `.ws-btn` 的 gap（系统 Label 默认约 10）。
struct TandemLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}
