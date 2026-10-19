import SwiftUI

/// 下划线标签栏：选中项加粗并带 2 px 强调色下划线。
struct UnderlineTabs<Tab: Hashable>: View {
    let tabs: [(tab: Tab, title: String)]
    @Binding var selection: Tab

    init(_ tabs: [(tab: Tab, title: String)], selection: Binding<Tab>) {
        self.tabs = tabs
        self._selection = selection
    }

    var body: some View {
        HStack(spacing: 18) {
            ForEach(tabs.indices, id: \.self) { index in
                let item = tabs[index]
                let selected = item.tab == selection
                Button { selection = item.tab } label: {
                    Text(item.title)
                        .font(.system(size: 13, weight: selected ? .semibold : .regular))
                        .foregroundStyle(selected ? Theme.textPrimary : Theme.textSecondary)
                        .frame(height: 32)
                        .overlay(alignment: .bottom) {
                            if selected { Rectangle().fill(Theme.accent).frame(height: 2) }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(height: 32)
    }
}
