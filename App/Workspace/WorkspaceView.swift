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
                    MirrorPane(model: model)
                        .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                    RightColumn()
                        .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
                }
                Rectangle().fill(Theme.separator).frame(height: 1)
                BottomPanes()
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

/// 右栏：两个标签。内容由 Task 13 提供（能力概览、剪贴板），这里先占位。
private struct RightColumn: View {
    private enum Tab: Hashable { case quickActions, clipboard }

    @State private var tab: Tab = .quickActions

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("快捷操作").tag(Tab.quickActions)
                Text("剪贴板").tag(Tab.clipboard)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(12)
            Rectangle().fill(Theme.separator).frame(height: 1)
            Group {
                switch tab {
                case .quickActions: Text("暂无快捷操作")
                case .clipboard: Text("暂无剪贴板内容")
                }
            }
            .font(.callout)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.panel)
    }
}

/// 底部两栏：左「最近截图」，右「操作记录」。内容由 Task 12 提供，这里先占位。
private struct BottomPanes: View {
    var body: some View {
        HStack(spacing: 0) {
            pane("最近截图") { Text("暂无截图") }
            Rectangle().fill(Theme.separator).frame(width: 1)
            pane("操作记录") { Text("暂无操作记录") }
        }
        .background(Theme.panel)
    }

    private func pane<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            content()
                .font(.callout)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity)
    }
}
