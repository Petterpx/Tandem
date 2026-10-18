import DeviceCore
import SwiftUI

/// 「快捷操作」标签：列出设备支持的能力（spec §6）。
struct QuickActionsTab: View {
    let commands: DeviceCommands
    let deviceID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("设备能力")
                .font(.caption)
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
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
