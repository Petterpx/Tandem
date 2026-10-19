import SwiftUI
import DeviceCore

/// 工作台左栏：设备列表（含保持中但已离开列表的设备），底部「无线配对…」「设置」。
struct DeviceSidebar: View {
    let model: AppModel
    let recording: RecordingService
    let locks: AILocks
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            Text("设备")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 4)
            list
            Rectangle().fill(Theme.border).frame(height: 1)
            footer
        }
        .background(Theme.sidebar)
    }

    private var selection: Binding<String?> {
        Binding(
            get: { model.selectedID },
            set: { id in
                guard let id, id != model.selectedID else { return }
                Task { await model.select(id) }
            })
    }

    @ViewBuilder private var list: some View {
        let devices = model.sidebarDevices
        if devices.isEmpty {
            VStack(spacing: 6) {
                if let error = model.startupError {
                    Text(error.message).foregroundStyle(Theme.textPrimary)
                    if let s = error.suggestion { Text(s).font(.caption).foregroundStyle(Theme.textSecondary) }
                } else {
                    Text("暂无设备").foregroundStyle(Theme.textSecondary)
                    Text("用 USB 连接手机，或点下方「无线配对…」")
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            .multilineTextAlignment(.center)
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: selection) {
                ForEach(devices) { device in
                    DeviceRow(device: device, isRecording: recording.isRecording(device.id),
                              isPopped: model.mirrors.popped.contains(device.id),
                              isLocked: locks.isLocked(device.id))
                        .tag(device.id)
                        .contextMenu { menu(for: device) }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private func menu(for device: DeviceInfo) -> some View {
        Button("弹出为独立窗口") { model.popOut(device.id) }
        Button("停止投屏") { Task { await model.stopMirroring(device.id) } }
            .disabled(!model.mirrors.kept.contains(device.id))
        Divider()
        Button("移除") {
            // 弹出窗口开着时一并关掉，否则会留下一个显示「已断开」的空窗口。
            dismissWindow(id: "device", value: device.id)
            Task { await model.remove(device.id) }
        }
        .disabled(device.state == .connected)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button {
                openWindow(id: "pairing")
            } label: {
                Label("无线配对…", systemImage: "wifi")
            }
            Spacer()
            SettingsLink {
                Label("设置", systemImage: "gearshape")
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.textPrimary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// 一行设备：状态点、名称、连接方式；禁止 AI 时显示锁，录屏中显示红点，已弹出时显示窗口图标。
private struct DeviceRow: View {
    let device: DeviceInfo
    let isRecording: Bool
    let isPopped: Bool
    let isLocked: Bool

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor).frame(width: 8, height: 8)
                .help(statusText)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .lineLimit(1)
                    .foregroundStyle(device.state == .connected ? Theme.textPrimary : Theme.textSecondary)
                Text("\(device.connection == .usb ? "USB" : "Wi-Fi") · \(statusText)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 4)
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .help("禁止 AI 操作")
                    .accessibilityLabel("禁止 AI 操作")
            }
            if isPopped {
                Image(systemName: "macwindow")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .help("已在独立窗口中显示")
            }
            if isRecording {
                Circle().fill(Theme.danger).frame(width: 8, height: 8)
                    .help("录屏中")
                    .accessibilityLabel("录屏中")
            }
        }
        .padding(.vertical, 3)
    }

    private var statusColor: Color {
        switch device.state {
        case .connected: Theme.success
        case .unauthorized: Theme.warning
        case .offline: Theme.textSecondary
        }
    }

    private var statusText: String {
        switch device.state {
        case .connected: "已连接"
        case .unauthorized: "未授权"
        case .offline: "已断开"
        }
    }
}
