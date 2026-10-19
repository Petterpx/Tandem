import SwiftUI
import DeviceCore

/// 截图 / 录屏按钮（工作台按钮行与弹出窗口底栏共用）。录屏中变红并显示 mm:ss 时长。
/// 所有动作经 DeviceCommands；不可用时置灰，悬停显示原因（spec §4.2 / §9）。
struct CaptureButtons: View {
    let commands: DeviceCommands
    let recording: RecordingService
    let deviceID: String
    let state: SessionState
    let origin: ToastOrigin
    /// 图标 / 文字颜色：工作台用 Theme.textPrimary，弹出窗口深色底栏用 Theme.onVideo。
    let tint: Color

    var body: some View {
        HStack(spacing: 4) {
            Button {
                let quality = ScreenshotQuality(modifiers: NSEvent.modifierFlags)
                Task { await commands.screenshot(deviceID, quality: quality, origin: origin) }
            } label: {
                if commands.screenshotInFlight(deviceID) == .screencap {
                    ProgressView().controlSize(.small).frame(width: 32, height: 26)
                } else {
                    Image(systemName: "camera").frame(width: 32, height: 26)
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(tint)
            .disabled(!commands.can(.screenshot, deviceID) || commands.screenshotInFlight(deviceID) == .screencap)
            .help(commands.can(.screenshot, deviceID) ? "截图 (⌘⇧S)，按住 ⌥ 为高清截图" : "该设备不支持截图")
            .accessibilityLabel("截图")

            recordButton
        }
    }

    private var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    @ViewBuilder private var recordButton: some View {
        let active = recording.active[deviceID]
        // 录屏进行中始终允许结束（会话结束时由 DeviceCommands 自动收尾）。
        let canRecord = commands.can(.record, deviceID)
        let enabled = active != nil || (canRecord && isRunning)
        Button {
            Task { await commands.toggleRecording(deviceID, origin: origin) }
        } label: {
            if let active {
                HStack(spacing: 4) {
                    Image(systemName: "stop.circle.fill")
                    TimelineView(.periodic(from: active.startedAt, by: 1)) { context in
                        Text(Self.clock(context.date.timeIntervalSince(active.startedAt)))
                            .font(.caption.monospacedDigit())
                    }
                }
                .foregroundStyle(Theme.danger)
                .frame(minWidth: 32, minHeight: 26)
            } else {
                Image(systemName: "record.circle").frame(width: 32, height: 26)
            }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(active == nil ? tint : Theme.danger)
        .disabled(!enabled)
        .help(helpText(recording: active != nil, canRecord: canRecord))
        .accessibilityLabel(active == nil ? "录屏" : "结束录屏")
    }

    private func helpText(recording: Bool, canRecord: Bool) -> String {
        if recording { return "结束录屏 (⌘⇧R)" }
        if !canRecord { return "该设备不支持录屏" }
        if !isRunning { return "投屏未运行，无法录屏" }
        return "开始录屏 (⌘⇧R)"
    }

    /// mm:ss（超过 99 分钟时分钟位自然变长）。
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// 面板错误条：只在错误属于本窗口当前显示的设备时出现，可关闭。
struct PanelErrorBanner: View {
    let runner: ActionRunner
    let deviceID: String?

    var body: some View {
        if let error = runner.lastError, error.deviceID == deviceID {
            let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius)
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                VStack(alignment: .leading, spacing: 2) {
                    Text(error.message).tandemText(.body).foregroundStyle(Theme.textPrimary)
                    if let s = error.suggestion {
                        Text(s).tandemText(.meta).foregroundStyle(Theme.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    runner.dismissError()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 10))
                }
                .buttonStyle(TandemButtonStyle(.icon, height: 22))
                .help("关闭")
                .accessibilityLabel("关闭错误提示")
            }
            .tandemCard(padding: EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
            .background(shape.fill(Theme.danger.opacity(0.06)))
            .overlay(shape.strokeBorder(Theme.danger.opacity(0.5), lineWidth: 1))
            .padding(10)
        }
    }
}
