import DeviceCore
import SwiftUI

/// 「快捷操作」的分段，自上而下排列（spec §3.1）；rawValue 用作折叠状态与 busy 的键。
enum QuickSectionID: String, CaseIterable {
    case network, apps, openURL, devOptions, system, custom

    var title: String {
        switch self {
        case .network: "网络"
        case .apps: "应用"
        case .openURL: "打开链接"
        case .devOptions: "开发者"
        case .system: "系统"
        case .custom: "自定义命令"
        }
    }

    /// 分段需要的设备能力。
    var capability: Capability {
        switch self {
        case .network: .network
        case .apps: .apps
        case .openURL: .openURL
        case .devOptions: .devOptions
        case .system: .systemSettings
        case .custom: .shell
        }
    }

    /// 是否有设备状态可读（决定是否显示「刷新」）。
    var readable: Bool {
        switch self {
        case .network, .apps, .devOptions, .system: true
        case .openURL, .custom: false
        }
    }
}

/// 分段容器：标题可点击折叠（状态存 UserDefaults），右上角「刷新」；设备缺少能力时整体置灰并注明「该设备不支持」。
struct QuickSection<Content: View>: View {
    let section: QuickSectionID
    let model: QuickActionsModel
    let deviceID: String
    @ViewBuilder let content: () -> Content

    private var collapsed: Bool { model.store.collapsedSections.contains(section.rawValue) }
    private var supported: Bool { model.commands.can(section.capability, deviceID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !collapsed {
                content()
                    .disabled(!supported)
                    .opacity(supported ? 1 : 0.45)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Button {
                model.store.toggleSection(section.rawValue)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 10)
                    Text(section.title).font(.caption.weight(.semibold))
                }
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Spacer()
            if !supported {
                Text("该设备不支持").font(.caption).foregroundStyle(Theme.textSecondary)
            } else if section.readable {
                Button {
                    Task { await model.refresh(deviceID, section: section) }
                } label: {
                    Image(systemName: "arrow.clockwise").font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
                .help("刷新")
            }
        }
    }
}

/// 读取失败时的占位：「—」，悬停显示原因（spec §3.2）。
struct UnreadableMark: View {
    let reason: String

    var body: some View {
        Text("—")
            .foregroundStyle(Theme.textSecondary)
            .help(reason)
    }
}

extension View {
    /// 只在有说明时挂上悬停提示，避免空的 help。
    @ViewBuilder
    func help(ifPresent text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}
