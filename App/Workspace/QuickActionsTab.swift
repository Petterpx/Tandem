import DeviceCore
import SwiftUI

/// 「快捷操作」标签：只展示当前设备支持的分段。
/// 出现时与选中设备变化时读取一次各分段状态，不定时轮询（spec §3.2）。
struct QuickActionsTab: View {
    let model: QuickActionsModel
    let deviceID: String
    let openLogs: (LogTarget) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                ForEach(QuickSectionID.visible(capabilities: model.commands.device(deviceID)?.capabilities ?? []), id: \.self) { section in
                    QuickSection(section: section, model: model, deviceID: deviceID) { body(of: section) }
                }
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 20, trailing: 16))
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task(id: deviceID) { await model.refreshAll(deviceID) }
    }

    @ViewBuilder
    private func body(of section: QuickSectionID) -> some View {
        switch section {
        case .network: NetworkSection(model: model, deviceID: deviceID)
        case .apps: AppsSection(model: model, deviceID: deviceID, openLogs: openLogs)
        // 输入框按设备独立，切换设备不带过去
        case .openURL: OpenURLSection(model: model, deviceID: deviceID).id(deviceID)
        case .system: SystemSection(model: model, deviceID: deviceID)
        case .devOptions: EmptyView()
        case .custom: CustomCommandsSection(model: model, deviceID: deviceID)
        }
    }
}
