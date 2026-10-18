import SwiftUI
import AppKit
import DeviceCore

/// 输入通道：保证触摸/按键/粘贴按产生顺序到达 session。
/// 每次出现（.task）创建新的 stream，消失时 finish；无消费者时丢弃输入。
final class InputRouter: @unchecked Sendable {
    enum Op: Sendable {
        case action(InputAction)
        case paste(String)
    }

    private let lock = NSLock()
    private var continuation: AsyncStream<Op>.Continuation?

    func open() -> AsyncStream<Op> {
        let (stream, c) = AsyncStream<Op>.makeStream(bufferingPolicy: .unbounded)
        lock.lock()
        continuation?.finish()
        continuation = c
        lock.unlock()
        return stream
    }

    func close() {
        lock.lock()
        continuation?.finish()
        continuation = nil
        lock.unlock()
    }

    func yield(_ op: Op) {
        lock.lock(); defer { lock.unlock() }
        continuation?.yield(op)
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
    let onInput: (InputAction) -> Void
    let onPaste: () -> Void

    func makeNSView(context: Context) -> VideoSurfaceView {
        let view = VideoSurfaceView()
        view.onInput = onInput
        view.onPaste = onPaste
        let coalescer = FrameCoalescer()
        coalescer.setSink { [weak view] frame in view?.show(frame) }
        session.setFrameHandler { coalescer.submit($0) }
        if let latest = session.latestFrame() { view.show(latest) }
        return view
    }

    func updateNSView(_ view: VideoSurfaceView, context: Context) {
        view.onInput = onInput
        view.onPaste = onPaste
        if case .running(let w, let h) = state {
            view.runningSize = CGSize(width: w, height: h)
        }
    }
}

struct DeviceWindowView: View {
    let device: DeviceInfo
    let session: any DeviceSession
    let state: SessionState
    let onRetry: () -> Void

    @State private var pump = InputRouter()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                VideoSurface(
                    session: session,
                    state: state,
                    onInput: { [pump] in pump.yield(.action($0)) },
                    onPaste: { [pump] in
                        if let text = NSPasteboard.general.string(forType: .string), !text.isEmpty {
                            pump.yield(.paste(text))
                        }
                    }
                )
                overlay
            }
            bottomBar
        }
        .background(Color.black)
        .task { await consume() }
    }

    private func consume() async {
        let stream = pump.open()
        defer { pump.close() }
        for await op in stream {
            if Task.isCancelled { break }
            switch op {
            case .action(let action):
                await session.send(action)
            case .paste(let text):
                do { try await session.setClipboard(text, paste: true) }
                catch { NSLog("MagicDevX: 粘贴失败: \(error)") }
            }
        }
    }

    @ViewBuilder private var overlay: some View {
        if device.state == .unauthorized {
            overlayBox { Text("请在手机上允许 USB 调试") }
        } else {
            switch state {
            case .connecting:
                overlayBox {
                    ProgressView()
                    Text("正在连接…")
                }
            case .disconnected:
                overlayBox { Text("已断开，设备重新连接后将自动恢复") }
            case .failed(let e):
                overlayBox {
                    Text(e.message)
                    if let s = e.suggestion { Text(s).font(.callout).foregroundStyle(.secondary) }
                    Button("重试", action: onRetry)
                }
            case .idle, .running:
                EmptyView()
            }
        }
    }

    private func overlayBox<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 10) { content() }
            .multilineTextAlignment(.center)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.black.opacity(0.7))
            .foregroundStyle(.white)
    }

    private var bottomBar: some View {
        HStack(spacing: 28) {
            navButton("chevron.backward", label: "返回", key: .back)
            navButton("circle", label: "主页", key: .home)
            navButton("square.on.square", label: "多任务", key: .recents)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 40)
        .background(Color(white: 0.1))
    }

    private func navButton(_ symbol: String, label: String, key: DeviceKey) -> some View {
        Button { pump.yield(.action(.key(key))) } label: {
            Image(systemName: symbol).foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}
