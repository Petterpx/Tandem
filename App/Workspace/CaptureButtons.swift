import SwiftUI
import DeviceCore

/// 截图 / 录屏按钮的外观：工作台浮动工具条，或弹出窗口深色底栏（纯图标，tint 为图标颜色）。
enum CaptureButtonsStyle {
    case toolbar
    case videoBar(tint: Color)
}

/// 截图 / 录屏按钮（工作台工具条与弹出窗口底栏共用）。录屏中变红并显示 mm:ss 时长。
/// 所有动作经 DeviceCommands；不可用时置灰，悬停显示原因（spec §4.2 / §9）。
struct CaptureButtons: View {
    let commands: DeviceCommands
    let recording: RecordingService
    let deviceID: String
    let state: SessionState
    let origin: ToastOrigin
    let style: CaptureButtonsStyle

    var body: some View {
        CaptureButtonsContent(
            style: style,
            canShot: commands.can(.screenshot, deviceID),
            shotBusy: commands.screenshotInFlight(deviceID) == .screencap,
            recordingStartedAt: recording.active[deviceID]?.startedAt,
            canRecord: commands.can(.record, deviceID),
            isRunning: isRunning,
            onShot: {
                let quality = ScreenshotQuality(modifiers: NSEvent.modifierFlags)
                Task { await commands.screenshot(deviceID, quality: quality, origin: origin) }
            },
            onRecord: {
                Task { await commands.toggleRecording(deviceID, origin: origin) }
            })
    }

    private var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// mm:ss（超过 99 分钟时分钟位自然变长）。
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    /// 工具条录屏中的按钮文字。
    static func stopTitle(_ seconds: TimeInterval) -> String {
        "停止 " + clock(seconds)
    }
}

/// 截图 / 录屏按钮的纯展示部分：只吃值，便于快照渲染。
struct CaptureButtonsContent: View {
    let style: CaptureButtonsStyle
    let canShot: Bool
    /// screencap 截图进行中：显示转圈并禁用。
    let shotBusy: Bool
    /// 录屏开始时间；nil 表示没在录。
    let recordingStartedAt: Date?
    let canRecord: Bool
    let isRunning: Bool
    let onShot: () -> Void
    let onRecord: () -> Void

    var body: some View {
        HStack(spacing: isToolbar ? 6 : 4) {
            shotButton
            recordButton
        }
    }

    private var isToolbar: Bool {
        if case .toolbar = style { return true }
        return false
    }

    @ViewBuilder private var shotButton: some View {
        let button = Button(action: onShot) {
            switch style {
            case .toolbar:
                Label {
                    Text("截图")
                } icon: {
                    if shotBusy { ProgressView().controlSize(.mini) } else { Image(systemName: "camera") }
                }
            case .videoBar:
                if shotBusy {
                    ProgressView().controlSize(.small).frame(width: 32, height: 26)
                } else {
                    Image(systemName: "camera").frame(width: 32, height: 26)
                }
            }
        }
        .disabled(!canShot || shotBusy)
        .help(canShot ? "截图 (⌘⇧S)，按住 ⌥ 为高清截图" : "该设备不支持截图")
        .accessibilityLabel("截图")
        switch style {
        case .toolbar: button.buttonStyle(TandemButtonStyle(.secondary))
        case .videoBar(let tint): button.buttonStyle(.borderless).foregroundStyle(tint)
        }
    }

    @ViewBuilder private var recordButton: some View {
        // 录屏进行中始终允许结束（会话结束时由 DeviceCommands 自动收尾）。
        let enabled = recordingStartedAt != nil || (canRecord && isRunning)
        let button = Button(action: onRecord) {
            switch style {
            case .toolbar:
                if let startedAt = recordingStartedAt {
                    TimelineView(.periodic(from: startedAt, by: 1)) { context in
                        Label(CaptureButtons.stopTitle(context.date.timeIntervalSince(startedAt)),
                              systemImage: "stop.circle.fill")
                            .monospacedDigit()
                    }
                    .foregroundStyle(Theme.danger)
                } else {
                    Label("录屏", systemImage: "record.circle")
                }
            case .videoBar:
                if let startedAt = recordingStartedAt {
                    HStack(spacing: 4) {
                        Image(systemName: "stop.circle.fill")
                        TimelineView(.periodic(from: startedAt, by: 1)) { context in
                            Text(CaptureButtons.clock(context.date.timeIntervalSince(startedAt)))
                                .font(.caption.monospacedDigit())
                        }
                    }
                    .foregroundStyle(Theme.danger)
                    .frame(minWidth: 32, minHeight: 26)
                } else {
                    Image(systemName: "record.circle").frame(width: 32, height: 26)
                }
            }
        }
        .disabled(!enabled)
        .help(helpText)
        .accessibilityLabel(recordingStartedAt == nil ? "录屏" : "结束录屏")
        switch style {
        case .toolbar: button.buttonStyle(TandemButtonStyle(.secondary))
        case .videoBar(let tint):
            button.buttonStyle(.borderless).foregroundStyle(recordingStartedAt == nil ? tint : Theme.danger)
        }
    }

    private var helpText: String {
        if recordingStartedAt != nil { return "结束录屏 (⌘⇧R)" }
        if !canRecord { return "该设备不支持录屏" }
        if !isRunning { return "投屏未运行，无法录屏" }
        return "开始录屏 (⌘⇧R)"
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
