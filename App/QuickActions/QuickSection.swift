import DeviceCore
import SwiftUI

/// 「快捷操作」的分段，自上而下排列（spec §3.1）；rawValue 用作折叠状态与 busy 的键。
enum QuickSectionID: String, CaseIterable {
    case network, apps, openURL, system, devOptions, custom

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

    /// 用户界面只展示支持的分段；开发者能力仍供模型与 MCP 使用。
    static func visible(capabilities: Set<Capability>) -> [QuickSectionID] {
        allCases.filter { $0 != .devOptions && capabilities.contains($0.capability) }
    }

    /// 是否有设备状态可读（决定是否显示「刷新」）。
    var readable: Bool {
        switch self {
        case .network, .apps, .devOptions, .system: true
        case .openURL, .custom: false
        }
    }
}

/// 分段外壳：标题、刷新与折叠按钮，以及内容。
struct QuickSectionChrome<Content: View>: View {
    let title: String
    let collapsed: Bool
    let onToggle: () -> Void
    let onRefresh: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.headerToCard) {
            SectionHeader(title) {
                HStack(spacing: 2) {
                    if let onRefresh {
                        Button(action: onRefresh) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11))
                        }
                        .buttonStyle(TandemButtonStyle(.ghostIcon, height: 22))
                        .help("刷新")
                        .accessibilityLabel("刷新\(title)")
                    }
                    Button(action: onToggle) {
                        Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(TandemButtonStyle(.ghostIcon, height: 22))
                    .accessibilityLabel(collapsed ? "展开\(title)" : "折叠\(title)")
                }
            }
            if !collapsed {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 分段容器：只负责从模型取折叠、能力与刷新，样式交给 `QuickSectionChrome`；折叠状态存 UserDefaults。
struct QuickSection<Content: View>: View {
    let section: QuickSectionID
    let model: QuickActionsModel
    let deviceID: String
    @ViewBuilder let content: () -> Content

    private var visible: Bool {
        QuickSectionID.visible(capabilities: model.commands.device(deviceID)?.capabilities ?? []).contains(section)
    }

    var body: some View {
        if visible {
            QuickSectionChrome(
                title: section.title,
                collapsed: model.store.collapsedSections.contains(section.rawValue),
                onToggle: { model.store.toggleSection(section.rawValue) },
                onRefresh: section.readable ? { Task { await model.refresh(deviceID, section: section) } } : nil,
                content: content)
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
