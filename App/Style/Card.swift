import SwiftUI

extension View {
    /// 白底描边圆角卡片。
    func tandemCard(padding: EdgeInsets = Metrics.cardPadding) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius)
        return self
            .padding(padding)
            .background(shape.fill(Theme.card))
            .overlay(shape.strokeBorder(Theme.cardBorder, lineWidth: 1))
            .shadow(color: Theme.shadow.opacity(0.04), radius: 1, y: 1)
    }
}

/// 卡片内的一行：左侧标签（可带副标题），右侧自定义内容。
struct CardRow<Trailing: View>: View {
    let label: String
    let subtitle: String?
    let trailing: Trailing

    init(_ label: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label).tandemText(.body).foregroundStyle(Theme.textPrimary)
                if let subtitle {
                    Text(subtitle).tandemText(.meta).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.vertical, subtitle == nil ? 0 : 6)
        .frame(minHeight: Metrics.cardRowMinHeight)
    }
}

/// 卡片行之间的分隔线。
struct CardDivider: View {
    var body: some View {
        Rectangle().fill(Theme.rowDivider).frame(height: 1)
    }
}
