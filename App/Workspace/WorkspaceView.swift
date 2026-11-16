import DeviceCore
import SwiftUI

/// 以 `--background` 拉起时只在本进程第一次出现工作台时关闭它；之后点 Dock 或菜单「打开工作台」照常打开。
/// 用户主动打开（requestOpenWorkspace）会先把它设为已处理，第一次出现的工作台若是用户打开的也不会被关闭。
@MainActor enum BackgroundLaunch {
    static var handled = false
}

/// 工作台主窗口（spec §2.1）：左栏设备列表，中间投屏，右栏「快捷操作 / 剪贴板 / AI」，底部「最近截图」「操作记录」。
struct WorkspaceView: View {
    let model: AppModel
    let services: AppServices
    @Environment(\.dismissWindow) private var dismissWindow

    /// 选中设备的名称：离开列表的设备沿用 lastKnown 信息。
    private var selectedName: String? {
        guard let id = model.selectedID else { return nil }
        return (model.devices.first { $0.id == id } ?? model.lastKnownDevices[id])?.name
    }

    var body: some View {
        // 固定布局：左栏与右栏定宽，投屏区占满剩余宽度
        HStack(spacing: 0) {
            DeviceSidebar(model: model, recording: services.recording, locks: services.locks)
                .frame(width: Metrics.sidebarWidth)
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    MirrorPane(model: model, services: services)
                        .frame(minWidth: Metrics.mirrorMinWidth, maxWidth: .infinity, maxHeight: .infinity)
                    RightColumn(services: services, deviceID: model.selectedID, deviceName: model.devices.first { $0.id == model.selectedID }?.name)
                        .frame(width: Metrics.panelWidth)
                }
                Rectangle().fill(Theme.border).frame(height: 1)
                BottomPanes(store: services.store, log: services.log)
                    .frame(height: Metrics.bottomHeight)
            }
        }
        .frame(minWidth: Metrics.sidebarWidth + Metrics.panelWidth + Metrics.mirrorMinWidth, minHeight: 600)
        .navigationTitle(WorkspaceText.windowTitle(deviceName: selectedName))
        .tint(Theme.accent)
        .focusedSceneValue(\.captureTarget, model.selectedID.map { CaptureTarget(deviceID: $0, origin: .workspace) })
        .onAppear {
            // 由 MCP / 登录项以 --background 拉起：关闭启动时自动出现的工作台，不开始投屏。
            // macOS 15 的 defaultLaunchBehavior(.suppressed) 更干净，但最低系统是 14。
            if !BackgroundLaunch.handled {
                BackgroundLaunch.handled = true
                if AppPolicy.isBackgroundLaunch(arguments: ProcessInfo.processInfo.arguments) {
                    dismissWindow(id: "workspace")
                    return
                }
            }
            Task { await model.workspaceAppeared() }
        }
        .onDisappear { Task { await model.workspaceDisappeared() } }
    }
}

/// 右栏标签。
enum RightTab: Hashable {
    case quickActions, files, clipboard, ai

    var title: String {
        switch self {
        case .quickActions: "快捷操作"
        case .files: "文件"
        case .clipboard: "剪贴板"
        case .ai: "AI"
        }
    }

    /// 标签与快捷操作使用相同的能力策略；无设备时只保留全局 AI 接入。
    static func visible(capabilities: Set<Capability>) -> [RightTab] {
        var tabs: [RightTab] = []
        if !QuickSectionID.visible(capabilities: capabilities).isEmpty { tabs.append(.quickActions) }
        if capabilities.contains(.files) { tabs.append(.files) }
        if capabilities.contains(.clipboard) { tabs.append(.clipboard) }
        tabs.append(.ai)
        return tabs
    }

    /// 切设备后原标签不可用时，按固定顺序回落到第一个可用标签。
    static func resolvedSelection(_ selected: RightTab, capabilities: Set<Capability>) -> RightTab {
        let tabs = visible(capabilities: capabilities)
        return tabs.contains(selected) ? selected : tabs[0]
    }
}

/// 右栏当前标签：放在可观察模型里，「在文件中查看」才能从外部切到「文件」。
@MainActor @Observable
final class WorkspaceTabs {
    var selected: RightTab = .quickActions
}

/// 右栏按设备能力展示标签；AI 接入始终可用。
private struct RightColumn: View {
    let services: AppServices
    let deviceID: String?
    let deviceName: String?
    @Environment(\.openWindow) private var openWindow

    private var capabilities: Set<Capability> { deviceID.flatMap { services.commands.device($0)?.capabilities } ?? [] }
    private var tab: RightTab { RightTab.resolvedSelection(services.tabs.selected, capabilities: capabilities) }

    var body: some View {
        VStack(spacing: 0) {
            PanelErrorBanner(runner: services.runner, deviceID: deviceID)
            RightPanelHeader(
                deviceName: deviceName, tabs: RightTab.visible(capabilities: capabilities),
                selection: Binding(get: { tab }, set: { services.tabs.selected = $0 }))
            switch (tab, deviceID) {
            case (.files, let deviceID?):
                FilesTab(model: services.filesModel, commands: services.commands, deviceID: deviceID)
            case (.ai, _):
                // 连接与接入是全局的，未选设备时也显示
                AITab(services: services, deviceID: deviceID)
            case (.quickActions, let deviceID?):
                QuickActionsTab(model: services.quickModel, deviceID: deviceID) { target in
                    services.requestLogs(deviceID, target: target)
                    openWindow(id: "logs", value: deviceID)
                }
            case (.clipboard, let deviceID?):
                // 按设备重建，输入框内容不会带到另一台设备
                ClipboardTab(commands: services.commands, clipboard: services.clipboard, deviceID: deviceID)
                    .id(deviceID)
            case (_, nil):
                Text("未选择设备")
                    .tandemText(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: capabilities, initial: true) { _, _ in
            guard deviceID != nil else { return }
            services.tabs.selected = tab
        }
        .onChange(of: services.tabs.selected) { _, _ in
            guard deviceID != nil else { return }
            services.tabs.selected = tab
        }
        .background(Theme.panel)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
    }
}

/// 底部两栏：左「最近截图」占满剩余宽度，右「操作记录」与右栏同宽（含左侧 1 px 描边）。
private struct BottomPanes: View {
    let store: CaptureStore
    let log: ActivityLog

    var body: some View {
        HStack(spacing: 0) {
            RecentCapturesStrip(store: store).frame(maxWidth: .infinity)
            ActivityLogView(log: log)
                .frame(width: Metrics.panelWidth)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
        }
        .background(Theme.windowBackground)
    }
}
