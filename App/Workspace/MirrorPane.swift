import SwiftUI
import DeviceCore

/// 工作台中间：选中设备的标题行 + 投屏画面 + 按钮行，放在带淡点阵的浅灰画布上。
struct MirrorPane: View {
    let model: AppModel
    let services: AppServices
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        ZStack {
            DotGrid()
            content
        }
        .overlay(alignment: .bottom) {
            // 避开下方按钮行（高度约 50pt），否则提示条会挡住截图 / 录屏按钮。
            CaptureToastView(toasts: services.toasts, store: services.store, origin: .workspace,
                             onReveal: services.reveal)
                .padding(.bottom, 56)
        }
        .animation(.default, value: services.toasts.current[.workspace]?.id)
        .background(Theme.canvas)
    }

    @ViewBuilder private var content: some View {
        if let id = model.selectedID, let device = model.devices.first(where: { $0.id == id }) ?? model.lastKnownDevices[id] {
            let isPresent = model.devices.contains { $0.id == id }
            VStack(spacing: 0) {
                MirrorHeader(model: model, device: device, isPresent: isPresent)
                Rectangle().fill(Theme.border).frame(height: 1)
                mirror(id: id, device: device, isPresent: isPresent)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            placeholder { Text("从左侧选择一台设备").foregroundStyle(Theme.textSecondary) }
        }
    }

    @ViewBuilder private func mirror(id: String, device: DeviceInfo, isPresent: Bool) -> some View {
        if model.mirrors.popped.contains(id) {
            // 同一台设备的画面同时只在一处显示。
            placeholder {
                Text("已在独立窗口中显示").foregroundStyle(Theme.textSecondary)
                Button("收回") {
                    // 先留在工作台里（保持会话），再关掉弹出窗口，避免会话被停掉又重启。
                    Task {
                        await model.select(id)
                        dismissWindow(id: "device", value: id)
                    }
                }
            }
        } else if !model.mirrors.wanted.contains(id) {
            placeholder {
                Text("已停止投屏").foregroundStyle(Theme.textSecondary)
                Button("开始投屏") { Task { await model.select(id) } }
            }
        } else if let session = model.session(for: id) {
            MirrorView(
                device: device, session: session, state: model.sessionStates[id] ?? .idle,
                isPresent: isPresent,
                romGuide: model.injectDenied.contains(id) ? model.romGuides[id] : nil,
                sizesWindow: false,
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
                    ProgressView()
                    Text("正在准备投屏…").foregroundStyle(Theme.textSecondary)
                } else {
                    Text("设备未连接，连接后将自动恢复").foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func placeholder<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 12) { content() }
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 投屏区上方：设备名、系统 · 分辨率 · 连接方式、状态徽标、「弹出为独立窗口」。
private struct MirrorHeader: View {
    let model: AppModel
    let device: DeviceInfo
    let isPresent: Bool

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name).font(.headline).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
            }
            StatusBadge(status: status)
            Spacer(minLength: 8)
            Button {
                model.popOut(device.id)
            } label: {
                Label("弹出为独立窗口", systemImage: "rectangle.portrait.on.rectangle.portrait")
            }
            .disabled(model.mirrors.popped.contains(device.id))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.panel)
    }

    private var subtitle: String {
        let system = device.platform == .android ? "Android" : "iOS"
        let kind = device.connection == .usb ? "USB" : "Wi-Fi"
        if case .running(let w, let h) = model.sessionStates[device.id] ?? .idle {
            return "\(system) · \(w)×\(h) · \(kind)"
        }
        return "\(system) · \(kind)"
    }

    private var status: StatusBadge.Status {
        let id = device.id
        if !isPresent || device.state == .offline { return .offline }
        if device.state == .unauthorized { return .unauthorized }
        if model.mirrors.popped.contains(id) { return .popped }
        guard model.mirrors.wanted.contains(id) else { return .stopped }
        switch model.sessionStates[id] ?? .idle {
        case .running: return .running
        case .idle, .connecting: return .connecting
        case .disconnected: return .offline
        case .failed: return .failed
        }
    }
}

private struct StatusBadge: View {
    enum Status {
        case running, connecting, popped, stopped, unauthorized, offline, failed
    }

    let status: Status

    var body: some View {
        Text(title)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var title: String {
        switch status {
        case .running: "投屏中"
        case .connecting: "连接中"
        case .popped: "已弹出"
        case .stopped: "未投屏"
        case .unauthorized: "未授权"
        case .offline: "已断开"
        case .failed: "失败"
        }
    }

    private var color: Color {
        switch status {
        case .running: Theme.accent
        case .connecting, .popped, .stopped, .offline: Theme.textSecondary
        case .unauthorized: Theme.warning
        case .failed: Theme.danger
        }
    }
}

/// 投屏区下方：返回 / 主页 / 多任务 | 截图 / 录屏。
private struct ControlRow: View {
    let sendKey: (DeviceKey) -> Void
    let commands: DeviceCommands
    let recording: RecordingService
    let deviceID: String
    let state: SessionState

    var body: some View {
        HStack(spacing: 4) {
            Spacer()
            iconButton("chevron.backward", label: "返回") { sendKey(.back) }
            iconButton("circle", label: "主页") { sendKey(.home) }
            iconButton("square.on.square", label: "多任务") { sendKey(.recents) }
            Rectangle().fill(Theme.border).frame(width: 1, height: 18).padding(.horizontal, 8)
            CaptureButtons(
                commands: commands, recording: recording, deviceID: deviceID, state: state,
                origin: .workspace, tint: Theme.textPrimary)
            Spacer()
        }
        .padding(.top, 12)
    }

    private func iconButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 32, height: 26)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.textPrimary)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// 画布背景的淡点阵。
private struct DotGrid: View {
    var spacing: CGFloat = 18
    var radius: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var y = spacing / 2
            while y < size.height {
                var x = spacing / 2
                while x < size.width {
                    path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    x += spacing
                }
                y += spacing
            }
            context.fill(path, with: .color(Theme.canvasDot))
        }
        .allowsHitTesting(false)
    }
}
