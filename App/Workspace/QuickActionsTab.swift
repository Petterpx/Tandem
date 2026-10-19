import DeviceCore
import SwiftUI

/// 「快捷操作」标签（spec §3.1）：自上而下为各分段，最下是「设备能力」概览。
/// 出现时与选中设备变化时读取一次各分段状态，不定时轮询（spec §3.2）。
struct QuickActionsTab: View {
    let model: QuickActionsModel
    let deviceID: String
    let deviceName: String
    let openLogs: (LogTarget) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                ForEach(QuickSectionID.allCases, id: \.self) { section in
                    QuickSection(section: section, model: model, deviceID: deviceID) { body(of: section) }
                }
                CapabilityOverviewCard(
                    deviceName: deviceName,
                    rows: Capability.allCases.map { (title: $0.title, supported: model.commands.can($0, deviceID)) })
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
        case .devOptions: DevOptionsSection(model: model, deviceID: deviceID)
        case .custom: CustomCommandsSection(model: model, deviceID: deviceID)
        }
    }
}

/// 设备能力概览（P3a spec §6）：列出设备支持的能力。
struct CapabilityOverviewCard: View {
    let deviceName: String
    let rows: [(title: String, supported: Bool)]

    static func title(deviceName: String) -> String { "能力概览 · \(deviceName)" }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.headerToCard) {
            SectionHeader(Self.title(deviceName: deviceName))
            VStack(spacing: 0) {
                ForEach(rows.indices, id: \.self) { index in
                    if index > 0 { CardDivider() }
                    let row = rows[index]
                    HStack(spacing: 8) {
                        Text(row.title).font(.system(size: 12)).foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 8)
                        StatusDot(size: 7, filled: row.supported)
                        Text(row.supported ? "支持" : "不支持")
                            .font(.system(size: 12))
                            .foregroundStyle(row.supported ? Theme.textPrimary : Theme.textSecondary)
                            .frame(width: 40, alignment: .trailing)
                    }
                    .padding(.vertical, 7)
                }
            }
            .tandemCard(padding: EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Capability {
    /// 能力的中文名。
    var title: String {
        switch self {
        case .mirror: "投屏"
        case .touch: "触控"
        case .keys: "按键"
        case .text: "文本输入"
        case .clipboard: "剪贴板"
        case .screenshot: "截图"
        case .record: "录屏"
        case .uiTree: "UI 树"
        case .network: "网络"
        case .apps: "应用管理"
        case .openURL: "打开链接"
        case .devOptions: "开发者选项"
        case .systemSettings: "系统设置"
        case .shell: "Shell"
        case .files: "文件"
        case .logs: "日志"
        }
    }
}
