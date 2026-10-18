import SwiftUI
import AppKit
import DeviceCore
import AndroidDriver

/// 截图 / 录屏快捷键作用的对象：当前窗口里的设备与提示条位置。
struct CaptureTarget: Equatable {
    let deviceID: String
    let origin: ToastOrigin
}

private struct CaptureTargetKey: FocusedValueKey {
    typealias Value = CaptureTarget
}

extension FocusedValues {
    /// 工作台提供选中设备与 `.workspace`；弹出窗口提供自己的 id 与 `.popup(id)`。
    var captureTarget: CaptureTarget? {
        get { self[CaptureTargetKey.self] }
        set { self[CaptureTargetKey.self] = newValue }
    }
}

/// 把 VideoToolbox 线程来的帧合并后投递到主线程。
final class FrameCoalescer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: VideoFrame?
    private var sink: (@MainActor (VideoFrame) -> Void)?

    func setSink(_ sink: @escaping @MainActor (VideoFrame) -> Void) {
        lock.lock(); defer { lock.unlock() }
        self.sink = sink
    }

    func submit(_ frame: VideoFrame) {
        lock.lock()
        let alreadyScheduled = pending != nil
        pending = frame
        lock.unlock()
        if alreadyScheduled { return }
        DispatchQueue.main.async { [self] in
            lock.lock()
            let frame = pending
            pending = nil
            let sink = sink
            lock.unlock()
            guard let frame, let sink else { return }
            MainActor.assumeIsolated { sink(frame) }
        }
    }
}

private struct VideoSurface: NSViewRepresentable {
    let session: any DeviceSession
    let state: SessionState
    let sizesWindow: Bool
    let onInput: (InputAction) -> Void
    let onPaste: () -> Void

    /// 保存订阅凭据，视图销毁时退订。
    final class Coordinator {
        var session: (any DeviceSession)?
        var token: FrameObserverToken?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleNSView(_ view: VideoSurfaceView, coordinator: Coordinator) {
        if let token = coordinator.token { coordinator.session?.removeFrameObserver(token) }
    }

    func makeNSView(context: Context) -> VideoSurfaceView {
        let view = VideoSurfaceView()
        view.sizesWindow = sizesWindow
        view.onInput = onInput
        view.onPaste = onPaste
        let coalescer = FrameCoalescer()
        coalescer.setSink { [weak view] frame in view?.show(frame) }
        context.coordinator.session = session
        context.coordinator.token = session.addFrameObserver { coalescer.submit($0) }
        if let latest = session.latestFrame() { view.show(latest) }
        return view
    }

    func updateNSView(_ view: VideoSurfaceView, context: Context) {
        view.sizesWindow = sizesWindow
        view.onInput = onInput
        view.onPaste = onPaste
        if case .running(let w, let h) = state {
            view.runningSize = CGSize(width: w, height: h)
        }
    }
}

/// 投屏画面：视频 + 状态遮罩 + ROM 横幅 + 输入泵，工作台与弹出窗口共用。
/// 画面下方的按钮行由调用方提供，通过 `sendKey` 把按键送进同一个输入泵，保证与触摸按顺序到达。
struct MirrorView<Bar: View>: View {
    let device: DeviceInfo
    let session: any DeviceSession
    let state: SessionState
    /// 设备是否仍在设备列表里；不在时显示「已断开」（画面停在最后一帧）。
    let isPresent: Bool
    let romGuide: RomGuide?
    /// true：弹出窗口，按视频比例调整窗口；false：工作台里只按视频比例缩放画面本身。
    let sizesWindow: Bool
    let onRetry: () -> Void
    let onReconnect: () -> Void
    let bar: (_ sendKey: @escaping (DeviceKey) -> Void) -> Bar

    @State private var pump = InputRouter()
    /// 最近一次 running 的视频尺寸；还没 running 过时按常见手机比例占位。
    @State private var videoSize = CGSize(width: 9, height: 19.5)

    init(
        device: DeviceInfo, session: any DeviceSession, state: SessionState, isPresent: Bool = true,
        romGuide: RomGuide? = nil, sizesWindow: Bool, onRetry: @escaping () -> Void,
        onReconnect: @escaping () -> Void = {},
        @ViewBuilder bar: @escaping (_ sendKey: @escaping (DeviceKey) -> Void) -> Bar
    ) {
        self.device = device
        self.session = session
        self.state = state
        self.isPresent = isPresent
        self.romGuide = romGuide
        self.sizesWindow = sizesWindow
        self.onRetry = onRetry
        self.onReconnect = onReconnect
        self.bar = bar
    }

    var body: some View {
        VStack(spacing: 0) {
            if sizesWindow {
                screen
            } else {
                screen
                    .aspectRatio(videoSize, contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            bar { [pump] key in pump.yield(.action(.key(key))) }
        }
        .task { await consume() }
        .onChange(of: state, initial: true) { _, state in
            if case .running(let w, let h) = state, w > 0, h > 0 { videoSize = CGSize(width: w, height: h) }
        }
    }

    private var screen: some View {
        ZStack {
            VideoSurface(
                session: session,
                state: state,
                sizesWindow: sizesWindow,
                onInput: { [pump] in pump.yield(.action($0)) },
                onPaste: { [pump] in
                    if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                        pump.yield(.paste(text))
                    }
                }
            )
            overlay
            if let romGuide {
                VStack { RomBannerView(guide: romGuide, onReconnect: onReconnect); Spacer() }
            }
        }
        .background(Theme.videoBackground)
    }

    private func consume() async {
        let session = session
        await pump.run { op in
            switch op {
            case .action(let action):
                await session.send(action)
            case .paste(let text):
                do { try await session.setClipboard(text, paste: true) }
                catch { NSLog("Tandem: 粘贴失败: \(error)") }
            }
        }
    }

    @ViewBuilder private var overlay: some View {
        if !isPresent {
            overlayBox { Text("已断开，设备重新连接后将自动恢复") }
        } else if device.state == .unauthorized {
            overlayBox { Text("请在手机上允许 USB 调试") }
        } else {
            switch state {
            case .idle, .connecting:
                overlayBox {
                    ProgressView()
                    Text("正在连接…")
                }
            case .disconnected:
                overlayBox {
                    Text("已断开，设备重新连接后将自动恢复")
                    Button("重试", action: onRetry)
                }
            case .failed(let e):
                overlayBox {
                    Text(e.message)
                    if let s = e.suggestion { Text(s).font(.callout).foregroundStyle(.secondary) }
                    Button("重试", action: onRetry)
                }
            case .running:
                EmptyView()
            }
        }
    }

    private func overlayBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10) { content() }
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.videoScrim)
            .foregroundStyle(Theme.onVideo)
    }
}
