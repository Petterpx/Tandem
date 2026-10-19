import SwiftUI

/// 右栏头部：「设备控制」与设备名，下方为下划线标签栏，底部 1 px 分隔线。
struct RightPanelHeader: View {
    let deviceName: String?
    let tabs: [RightTab]
    @Binding var selection: RightTab

    init(deviceName: String?, tabs: [RightTab], selection: Binding<RightTab>) {
        self.deviceName = deviceName
        self.tabs = tabs
        self._selection = selection
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("设备控制").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                if let deviceName {
                    Text(deviceName).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            UnderlineTabs(tabs.map { (tab: $0, title: $0.title) }, selection: $selection)
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 0, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}
