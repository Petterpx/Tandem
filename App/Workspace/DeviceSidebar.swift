import AppKit
import SwiftUI
import DeviceCore

/// 工作台左栏：应用头部、设备列表（含保持中但已离开列表的设备），底部「无线配对…」「设置」。
struct DeviceSidebar: View {
    let model: AppModel
    let recording: RecordingService
    let locks: AILocks
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @FocusState private var listFocused: Bool

    var body: some View {
        let devices = model.sidebarDevices
        SidebarChrome(count: devices.count, onPair: { openWindow(id: "pairing") }) {
            if devices.isEmpty {
                empty
            } else {
                list(devices)
            }
        }
    }

    private func select(_ id: String) {
        guard id != model.selectedID else { return }
        Task { await model.select(id) }
    }

    private var empty: some View {
        VStack(spacing: 6) {
            if let error = model.startupError {
                Text(error.message).tandemText(.body).foregroundStyle(Theme.textPrimary)
                if let s = error.suggestion { Text(s).tandemText(.meta).foregroundStyle(Theme.textSecondary) }
            } else {
                Text("暂无设备").tandemText(.body).foregroundStyle(Theme.textSecondary)
                Text("用 USB 连接手机，或点下方「无线配对…」")
                    .tandemText(.meta).foregroundStyle(Theme.textSecondary)
            }
        }
        .multilineTextAlignment(.center)
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func list(_ devices: [DeviceInfo]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(devices) { device in
                        let popped = model.mirrors.popped.contains(device.id)
                        DeviceRowView(
                            device: device, isSelected: device.id == model.selectedID,
                            isRecording: recording.isRecording(device.id), isPopped: popped,
                            isLocked: locks.isLocked(device.id),
                            onPop: !popped && device.state == .connected ? { model.popOut(device.id) } : nil)
                            .id(device.id)
                            .onTapGesture {
                                select(device.id)
                                listFocused = true
                            }
                            .contextMenu { menu(for: device) }
                    }
                }
                .padding(.horizontal, 8)
            }
            // 点击行后列表取得焦点，↑ / ↓ 切换相邻设备
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.upArrow) { move(-1, in: devices, proxy: proxy) }
            .onKeyPress(.downArrow) { move(1, in: devices, proxy: proxy) }
        }
    }

    private func move(_ step: Int, in devices: [DeviceInfo], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard let id = AppPolicy.adjacentID(devices.map(\.id), from: model.selectedID, step: step) else { return .ignored }
        select(id)
        proxy.scrollTo(id)
        return .handled
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
}

/// 左栏外框：头部、「设备」标题、列表区与底部按钮。列表区由调用方给出（快照里用普通 VStack 代替 ScrollView）。
struct SidebarChrome<Content: View>: View {
    let count: Int
    let onPair: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            header
            SectionHeader("设备", badge: Chip("\(count)", tone: .count))
                .padding(.vertical, 8)
                .padding(.horizontal, 16)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            footer
        }
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Tandem").tandemText(.headerTitle).foregroundStyle(Theme.textPrimary)
                Text("同驾 · 你和 AI 一起驾驶测试机").tandemText(.meta).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 14)
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
    }

    private var footer: some View {
        VStack(spacing: 6) {
            Button(action: onPair) { footerLabel("无线配对…", systemImage: "wifi") }
                .buttonStyle(TandemButtonStyle(.secondary))
            SettingsLink { footerLabel("设置", systemImage: "gearshape") }
                .buttonStyle(TandemButtonStyle(.secondary))
        }
        .padding(10)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    /// 整宽、左对齐，图标 14 pt。
    private func footerLabel(_ title: String, systemImage: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage).font(.system(size: 14))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 一行设备：手机图标、名称（已弹出时带芯片）、状态点与连接方式；禁止 AI 时显示锁，录屏中显示红点。
/// 悬停且可弹出时，右侧出现「弹出为独立窗口」按钮。
struct DeviceRowView: View {
    let device: DeviceInfo
    let isSelected: Bool
    let isRecording: Bool
    let isPopped: Bool
    let isLocked: Bool
    /// 只在未弹出且已连接时传入。
    let onPop: (() -> Void)?
    @State private var hovered = false

    init(device: DeviceInfo, isSelected: Bool, isRecording: Bool, isPopped: Bool, isLocked: Bool, onPop: (() -> Void)?) {
        self.device = device
        self.isSelected = isSelected
        self.isRecording = isRecording
        self.isPopped = isPopped
        self.isLocked = isLocked
        self.onPop = onPop
    }

    /// 「USB · 已连接」。
    static func subtitle(_ device: DeviceInfo) -> String {
        "\(device.connection == .usb ? "USB" : "Wi-Fi") · \(statusText(device.state))"
    }

    static func dotColor(_ state: DeviceState) -> Color {
        state == .connected ? Theme.success : Theme.dotOff
    }

    /// 未授权的行发淡。
    static func opacity(_ state: DeviceState) -> Double {
        state == .unauthorized ? 0.55 : 1
    }

    private static func statusText(_ state: DeviceState) -> String {
        switch state {
        case .connected: "已连接"
        case .unauthorized: "未授权"
        case .offline: "已断开"
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.rowRadius)
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .font(.system(size: 18))
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(device.name)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if isPopped { Chip("已弹出", tone: .accent) }
                }
                HStack(spacing: 5) {
                    StatusDot(size: 6, color: Self.dotColor(device.state))
                    Text(Self.subtitle(device))
                        .tandemText(.meta)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.tandem(.meta))
                    .foregroundStyle(Theme.textSecondary)
                    .help("禁止 AI 操作")
                    .accessibilityLabel("禁止 AI 操作")
            }
            if isRecording {
                Circle().fill(Theme.danger).frame(width: 6, height: 6)
                    .help("录屏中")
                    .accessibilityLabel("录屏中")
            }
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 40))
        .background {
            if isSelected {
                shape.fill(Theme.card)
                    .shadow(color: Theme.shadow.opacity(0.08), radius: 1.5, y: 1)
                    .overlay(shape.strokeBorder(Theme.cardBorder, lineWidth: 0.5))
            } else if hovered {
                shape.fill(Theme.hover)
            }
        }
        .overlay(alignment: .trailing) {
            if hovered, let onPop {
                Button(action: onPop) { Image(systemName: "arrow.up.right") }
                    .buttonStyle(TandemButtonStyle(.icon, height: 26, radius: 7))
                    .help(WorkspaceText.popToggleTitle(popped: false))
                    .accessibilityLabel(WorkspaceText.popToggleTitle(popped: false))
                    .padding(.trailing, 6)
            }
        }
        .contentShape(shape)
        .opacity(Self.opacity(device.state))
        .onHover { hovered = $0 }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
