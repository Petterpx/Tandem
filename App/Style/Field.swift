import SwiftUI

/// 输入框样式：圆角描边，可选等宽与多行。
struct TandemFieldStyle: ViewModifier {
    var mono = false
    var multiline = false

    init(mono: Bool = false, multiline: Bool = false) {
        self.mono = mono
        self.multiline = multiline
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.buttonRadius)
        content
            .textFieldStyle(.plain)
            .tandemText(mono ? .mono : .button)
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, multiline ? 6 : 0)
            .frame(minHeight: 30, maxHeight: multiline ? nil : 30)
            .background(shape.fill(Theme.card))
            .overlay(shape.strokeBorder(Theme.controlBorder, lineWidth: 1))
    }
}

extension View {
    func tandemField(mono: Bool = false, multiline: Bool = false) -> some View {
        modifier(TandemFieldStyle(mono: mono, multiline: multiline))
    }
}
