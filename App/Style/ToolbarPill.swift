import SwiftUI

/// 画布上悬浮的半透明工具条。
struct ToolbarPill<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.pillRadius)
        HStack(spacing: 6) { content }
            .padding(6)
            .background(shape.fill(Theme.card.opacity(0.85)))
            .overlay(shape.strokeBorder(Theme.cardBorder, lineWidth: 1))
            .shadow(color: Theme.shadow.opacity(0.04), radius: 1, y: 1)
    }
}
