import DeviceCore
import SwiftUI

/// 「快捷操作」标签（spec §3.1）：自上而下为各分段，最下是「设备能力」概览。
/// 出现时与选中设备变化时读取一次各分段状态，不定时轮询（spec §3.2）。
struct QuickActionsTab: View {
    let model: QuickActionsModel
    let deviceID: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                QuickSection(section: .network, model: model, deviceID: deviceID) {
                    NetworkSection(model: model, deviceID: deviceID)
                }
                divider
                QuickSection(section: .apps, model: model, deviceID: deviceID) {
                    AppsSection(model: model, deviceID: deviceID)
                }
                divider
                QuickSection(section: .openURL, model: model, deviceID: deviceID) {
                    OpenURLSection(model: model, deviceID: deviceID)
                }
                divider
                CapabilityOverview(commands: model.commands, deviceID: deviceID)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .task(id: deviceID) { await model.refreshAll(deviceID) }
    }

    private var divider: some View {
        Rectangle().fill(Theme.separator).frame(height: 1)
    }
}

/// 设备能力概览（P3a spec §6）：列出设备支持的能力。
private struct CapabilityOverview: View {
    let commands: DeviceCommands
    let deviceID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设备能力")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            ForEach(Capability.allCases, id: \.self) { capability in
                let supported = commands.can(capability, deviceID)
                HStack {
                    Text(capability.title).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(supported ? "✓" : "—")
                        .foregroundStyle(supported ? Theme.success : Theme.textSecondary)
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
        }
        .padding(.bottom, 8)
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
        }
    }
}
