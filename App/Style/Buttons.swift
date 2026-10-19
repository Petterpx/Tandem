import SwiftUI

/// 工作台统一按钮样式：次要 / 主要 / 图标 / 链接四种。
struct TandemButtonStyle: ButtonStyle {
    enum Kind { case secondary, primary, icon, ghostIcon, link }

    let kind: Kind
    var height: CGFloat
    var tint: Color?

    init(_ kind: Kind, height: CGFloat = Metrics.buttonHeight, tint: Color? = nil) {
        self.kind = kind
        self.height = height
        self.tint = tint
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
            let shape = RoundedRectangle(cornerRadius: Metrics.buttonRadius)
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
                        .frame(width: style.height, height: style.height)
                        .background(shape.fill(colors.fill))
                        .overlay(shape.strokeBorder(colors.stroke, lineWidth: 1))
                case .ghostIcon:
                    // 无底无边的次要图标，悬停时才出现底色
                    configuration.label
                        .foregroundStyle(colors.text)
                        .frame(width: style.height, height: style.height)
                        .background(shape.fill(colors.fill))
                case .secondary, .primary:
                    configuration.label
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
