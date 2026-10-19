import SwiftUI

/// 区块标题：小号字距标题 + 可选徽标 + 靠右的尾部内容。
struct SectionHeader<Trailing: View>: View {
    let title: String
    let badge: Chip?
    let trailing: Trailing

    init(_ title: String, badge: Chip? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.badge = badge
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title).tandemText(.sectionTitle).foregroundStyle(Theme.textSecondary)
            if let badge { badge }
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension SectionHeader where Trailing == EmptyView {
    init(_ title: String, badge: Chip? = nil) {
        self.init(title, badge: badge) { EmptyView() }
    }
}
