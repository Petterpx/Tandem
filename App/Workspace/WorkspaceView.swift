import SwiftUI

/// 工作台主窗口（spec §2.1）：左栏设备列表，中间投屏，右栏「快捷操作 / 剪贴板」，底部「最近截图」「操作记录」。
struct WorkspaceView: View {
    let model: AppModel
    let services: AppServices

    var body: some View {
        HSplitView {
            DeviceSidebar(model: model, recording: services.recording)
                .frame(minWidth: 190, idealWidth: 220, maxWidth: 280)
            VStack(spacing: 0) {
                HSplitView {
                    MirrorPane(model: model, services: services)
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    RightColumn(services: services, deviceID: model.selectedID)
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                }
                Rectangle().fill(Theme.separator).frame(height: 1)
                BottomPanes(store: services.store, log: services.log)
                    .frame(height: 150)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .tint(Theme.accent)
        .focusedSceneValue(\.captureTarget, model.selectedID.map { CaptureTarget(deviceID: $0, origin: .workspace) })
        .onAppear { Task { await model.workspaceAppeared() } }
        .onDisappear { Task { await model.workspaceDisappeared() } }
    }
}

/// 右栏：两个标签，「快捷操作」（能力概览）与「剪贴板」。
private struct RightColumn: View {
    let services: AppServices
    let deviceID: String?

    private enum Tab: Hashable { case quickActions, clipboard }

    @State private var tab: Tab = .quickActions

    var body: some View {
        VStack(spacing: 0) {
            PanelErrorBanner(runner: services.runner, deviceID: deviceID)
            Picker("", selection: $tab) {
                Text("快捷操作").tag(Tab.quickActions)
                Text("剪贴板").tag(Tab.clipboard)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Rectangle().fill(Theme.separator).frame(height: 1)
            if let deviceID {
                switch tab {
                case .quickActions: QuickActionsTab(commands: services.commands, deviceID: deviceID)
                case .clipboard:
                    // 按设备重建，输入框内容不会带到另一台设备
                    ClipboardTab(commands: services.commands, clipboard: services.clipboard, deviceID: deviceID)
                        .id(deviceID)
                }
            } else {
                Text("未选择设备")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Theme.panel)
    }
}

/// 底部两栏：左「最近截图」，右「操作记录」。
private struct BottomPanes: View {
    let store: CaptureStore
    let log: ActivityLog

    var body: some View {
        HStack(spacing: 0) {
            RecentCapturesStrip(store: store).frame(maxWidth: .infinity)
            Rectangle().fill(Theme.separator).frame(width: 1)
            ActivityLogView(log: log).frame(maxWidth: .infinity)
        }
        .background(Theme.panel)
    }
}
