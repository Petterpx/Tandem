import SwiftUI
import DeviceCore
import AndroidDriver

/// 弹出窗口的内容：共用的 MirrorView，加固定高度的深色导航底栏（窗口比例只作用于底栏以上的视频区域）。
struct DeviceWindowView: View {
    let device: DeviceInfo
    let services: AppServices
    let session: any DeviceSession
    let state: SessionState
    /// 设备是否仍在设备列表里；不在时显示「已断开」（画面停在最后一帧）。
    var isPresent = true
    var romGuide: RomGuide? = nil
    let onRetry: () -> Void
    var onReconnect: () -> Void = {}

    var body: some View {
        MirrorView(
            device: device, session: session, state: state, isPresent: isPresent, romGuide: romGuide,
            sizesWindow: true, onRetry: onRetry, onReconnect: onReconnect, presence: services.presence
        ) { sendKey in
            bottomBar(sendKey)
        }
        .background(Theme.videoBackground)
        .overlay(alignment: .top) {
            PanelErrorBanner(runner: services.runner, deviceID: device.id)
        }
        .overlay(alignment: .bottom) {
            CaptureToastView(toasts: services.toasts, store: services.store, origin: .popup(device.id))
                .padding(.bottom, ViewGeometry.bottomBarHeight)
        }
    }

    private func bottomBar(_ sendKey: @escaping (DeviceKey) -> Void) -> some View {
        HStack(spacing: 28) {
            navButton("chevron.backward", label: "返回") { sendKey(.back) }
            navButton("circle", label: "主页") { sendKey(.home) }
            navButton("square.on.square", label: "多任务") { sendKey(.recents) }
            CaptureButtons(
                commands: services.commands, recording: services.recording, deviceID: device.id, state: state,
                origin: .popup(device.id), tint: Theme.onVideo)
        }
        .frame(maxWidth: .infinity)
        .frame(height: ViewGeometry.bottomBarHeight)
        .background(Theme.videoChrome)
    }

    private func navButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).foregroundStyle(Theme.onVideo)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
