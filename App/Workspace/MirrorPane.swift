import SwiftUI
import DeviceCore

/// 工作台中间：选中设备的头部 + 手机外框里的投屏画面 + 浮动工具条，放在带淡点阵的浅灰画布上。
struct MirrorPane: View {
    let model: AppModel
    let services: AppServices
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ZStack {
            Theme.canvas
            DotGrid()
            content
        }
        .overlay(alignment: .bottom) {
            // 避开下方浮动工具条（高约 42pt + 下内边距 16pt），否则提示条会挡住截图 / 录屏按钮。
            CaptureToastView(toasts: services.toasts, store: services.store, origin: .workspace,
                             onReveal: services.reveal)
                .padding(.bottom, 64)
        }
        .animation(.default, value: services.toasts.current[.workspace]?.id)
    }

    @ViewBuilder private var content: some View {
        if let id = model.selectedID, let device = model.devices.first(where: { $0.id == id }) ?? model.lastKnownDevices[id] {
            let isPresent = model.devices.contains { $0.id == id }
            let popped = model.mirrors.popped.contains(id)
            let state = model.sessionStates[id] ?? .idle
            VStack(spacing: 0) {
                MirrorHeaderBar(
                    name: device.name,
                    meta: WorkspaceText.deviceMeta(
                        platform: device.platform, runningSize: Self.runningSize(state), connection: device.connection),
                    status: MirrorStatus.resolve(
                        isPresent: isPresent, deviceState: device.state, popped: popped,
                        wanted: model.mirrors.wanted.contains(id), session: state),
                    popped: popped,
                    onTogglePop: { popped ? unpop(id) : model.popOut(id) })
                mirror(id: id, device: device, isPresent: isPresent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            placeholder { Text("从左侧选择一台设备").tandemText(.body).foregroundStyle(Theme.textSecondary) }
        }
    }

    @ViewBuilder private func mirror(id: String, device: DeviceInfo, isPresent: Bool) -> some View {
        if model.mirrors.popped.contains(id) {
            // 同一台设备的画面同时只在一处显示。
            placeholder {
                Text("已在独立窗口中显示").tandemText(.body).foregroundStyle(Theme.textSecondary)
                Button("收回") { unpop(id) }
                    .buttonStyle(TandemButtonStyle(.secondary))
            }
        } else if !model.mirrors.wanted.contains(id) {
            placeholder {
                Text("已停止投屏").tandemText(.body).foregroundStyle(Theme.textSecondary)
                Button("开始投屏") { Task { await model.select(id) } }
                    .buttonStyle(TandemButtonStyle(.secondary))
            }
        } else if let session = model.session(for: id) {
            MirrorView(
                device: device, session: session, state: model.sessionStates[id] ?? .idle,
                isPresent: isPresent,
                romGuide: model.injectDenied.contains(id) ? model.romGuides[id] : nil,
                sizesWindow: false, chrome: .bezel,
                onRetry: { Task { await model.reconnect(id) } },
                onReconnect: { Task { await model.reconnect(id) } },
                presence: services.presence,
                transfers: services.transfers, commands: services.commands,
                fileStore: services.fileStore, origin: .workspace
            ) { sendKey in
                ControlRow(
                    sendKey: sendKey, commands: services.commands, recording: services.recording,
                    deviceID: id, state: model.sessionStates[id] ?? .idle)
            }
            // 切换设备时重建视频视图、帧订阅与输入泵。
            .id(id)
        } else {
            placeholder {
                if isPresent {
                    ProgressView().controlSize(.small)
                    Text("正在准备投屏…").tandemText(.body).foregroundStyle(Theme.textSecondary)
                } else {
                    Text("设备未连接，连接后将自动恢复").tandemText(.body).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    /// 收回独立窗口：先留在工作台里（保持会话），再关掉弹出窗口，避免会话被停掉又重启。
    private func unpop(_ id: String) {
        Task {
            await model.select(id)
            dismissWindow(id: "device", value: id)
        }
    }

    private static func runningSize(_ state: SessionState) -> CGSize? {
        if case .running(let w, let h) = state { return CGSize(width: w, height: h) }
        return nil
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12) { content() }
            .multilineTextAlignment(.center)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 投屏区上方的单行头部：设备名、系统 · 分辨率 · 连接方式、状态胶囊、「弹出 / 收回独立窗口」。
struct MirrorHeaderBar: View {
    let name: String
    let meta: String
    let status: MirrorStatus
    let popped: Bool
    let onTogglePop: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text(name).tandemText(.headerTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
            Text(meta).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(1)
            Chip(status.title, tone: status.tone, dot: status == .running)
            Spacer(minLength: 8)
            Button(action: onTogglePop) {
                Label(WorkspaceText.popToggleTitle(popped: popped), systemImage: "arrow.up.right")
            }
            .buttonStyle(TandemButtonStyle(.secondary))
        }
        .padding(.horizontal, 16)
        .frame(height: Metrics.deviceHeaderHeight)
        .background(Theme.windowBackground)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

/// 外框下方的浮动工具条：返回 / 主页 / 多任务 | 截图 / 录屏。
private struct ControlRow: View {
    let sendKey: (DeviceKey) -> Void
    let commands: DeviceCommands
    let recording: RecordingService
    let deviceID: String
    let state: SessionState

    var body: some View {
        ToolbarPill {
            if commands.can(.keys, deviceID) {
                iconButton("chevron.backward", label: "返回") { sendKey(.back) }
                iconButton("circle", label: "主页") { sendKey(.home) }
                iconButton("square.on.square", label: "多任务") { sendKey(.recents) }
                Rectangle().fill(Theme.border).frame(width: 1, height: 20).padding(.horizontal, 4)
            }
            CaptureButtons(
                commands: commands, recording: recording, deviceID: deviceID, state: state,
                origin: .workspace, style: .toolbar)
        }
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(TandemButtonStyle(.icon))
            .help(label)
            .accessibilityLabel(label)
    }
}
