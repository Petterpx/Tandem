import AppKit
import SwiftUI

/// 提示条倒计时：悬停时暂停，移开后按剩余时间继续。
struct ToastCountdown: Equatable {
    static let total: Duration = .seconds(2)

    /// 之前各段已走过的时间（不含正在走的这段）。
    private var elapsed: Duration = .zero
    /// 正在计时时为这段的起点；暂停或未开始时为 nil。
    private var runningSince: ContinuousClock.Instant?

    init() {}

    mutating func resume(at now: ContinuousClock.Instant) {
        if runningSince == nil { runningSince = now }
    }

    mutating func pause(at now: ContinuousClock.Instant) {
        guard let since = runningSince else { return }
        elapsed += now - since
        runningSince = nil
    }

    /// 正在计时（已开始且未暂停）。
    var isRunning: Bool { runningSince != nil }

    func remaining(at now: ContinuousClock.Instant) -> Duration {
        let running = runningSince.map { now - $0 } ?? .zero
        return max(.zero, Self.total - elapsed - running)
    }
}

/// 指针相对提示条的变化。App 失去激活、窗口失去 key 时 `onHover(false)` 不会触发
/// （例如点「在 Finder 中显示」后 Finder 到前台），这两种也当作移开。
enum ToastPointerEvent {
    case entered, exited, appResignedActive, windowResignedKey
}

/// 提示条的计时状态：悬停时暂停，移开（含失去激活 / 失去 key）后继续。
struct ToastTimer: Equatable {
    private(set) var countdown = ToastCountdown()
    private(set) var hovering = false

    /// 开始计时；指针已在提示条上时保持暂停。
    mutating func start(at now: ContinuousClock.Instant) {
        if !hovering { countdown.resume(at: now) }
    }

    mutating func handle(_ event: ToastPointerEvent, at now: ContinuousClock.Instant) {
        switch event {
        case .entered:
            hovering = true
            countdown.pause(at: now)
        case .exited, .appResignedActive, .windowResignedKey:
            hovering = false
            countdown.resume(at: now)
        }
    }
}

/// 提示条文案（录屏时长复用 `CaptureButtons.clock`，故在主线程）。
@MainActor enum ToastText {
    static func title(_ content: ToastContent) -> String {
        switch content {
        case .capture(let item, let note): item.kind == .recording ? (note ?? "录屏已保存") : "截图已保存"
        case .transfer(let notice): notice.title
        }
    }

    /// 截图为附注（没有时为文件名），录屏为 `mm:ss · 大小`，传输为说明。
    static func subtitle(_ content: ToastContent) -> String? {
        switch content {
        case .capture(let item, let note):
            if item.kind == .recording {
                return "\(CaptureButtons.clock(item.duration ?? 0)) · "
                    + ByteCountFormatter.string(fromByteCount: item.fileSize, countStyle: .file)
            }
            return note ?? item.url.lastPathComponent
        case .transfer(let notice):
            return notice.detail
        }
    }

    static func isError(_ content: ToastContent) -> Bool {
        if case .transfer(let notice) = content { return notice.isError }
        return false
    }
}

/// 截图 / 录屏 / 传输提示条：读取 `toasts.current[origin]`，2 秒后消失，悬停时暂停；点任何按钮或拖出缩略图后立即收起。
struct CaptureToastView: View {
    let toasts: ToastCenter
    let store: CaptureStore
    let origin: ToastOrigin
    /// 提示条贴着哪条边出现：工作台在顶部，弹出窗口在底部。
    var edge: VerticalEdge = .top
    /// 「在文件中查看」：由调用方接到文件页（Task 13）。
    var onReveal: (RevealTarget) -> Void = { _ in }

    var body: some View {
        if let toast = toasts.current[origin] {
            TimedToast(
                toast: toast, store: store, onReveal: onReveal,
                begin: { toasts.beginShowing(toast.id, in: origin, at: .now) },
                perform: { toasts.performAndDismiss(toast.id, in: origin, action: $0) },
                dismiss: { toasts.dismiss(toast.id, in: origin) })
                .id(toast.id)
                .padding(.horizontal, 12)
                .transition(.move(edge: edge == .top ? .top : .bottom).combined(with: .opacity))
        }
    }
}

/// 带计时的提示条：计时由 `.task(id: timer)` 驱动，暂停 / 继续时按剩余时间重新等待；视图消失即收起。
private struct TimedToast: View {
    let toast: CaptureToast
    let store: CaptureStore
    let onReveal: (RevealTarget) -> Void
    /// 出现时调用；发出太久才出现时返回 false（ToastCenter 已收起）。
    let begin: () -> Bool
    /// 执行动作后立即收起。
    let perform: (() -> Void) -> Void
    let dismiss: () -> Void

    @State private var timer = ToastTimer()
    @State private var host = HostWindow()

    var body: some View {
        ToastCardView(
            content: toast.content,
            onCopy: { item in perform { store.copy(item) } },
            onShowInFinder: { item in perform { store.reveal(item) } },
            onReveal: { target in perform { onReveal(target) } },
            onDragStart: dismiss)
            .background(HostWindowReader(host: host))
            .onAppear { if begin() { timer.start(at: .now) } }
            // 宿主被拆掉（切换设备、关窗口）时一并收起，避免之后换个地方再弹出来。
            .onDisappear(perform: dismiss)
            .onHover { timer.handle($0 ? .entered : .exited, at: .now) }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
                timer.handle(.appResignedActive, at: .now)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
                // 只认自己所在的窗口失去 key
                guard let window = note.object as? NSWindow, window === host.window else { return }
                timer.handle(.windowResignedKey, at: .now)
            }
            .task(id: timer) {
                // 悬停（暂停）或尚未开始时不等待；状态一变任务就按新的剩余时间重来。
                guard timer.countdown.isRunning else { return }
                do { try await Task.sleep(for: timer.countdown.remaining(at: .now)) } catch { return }
                dismiss()
            }
    }
}

/// 提示条所在的窗口；用引用保存，写入时不触发视图刷新。
private final class HostWindow {
    weak var window: NSWindow?
}

/// 记下宿主窗口：视图进入窗口时写入 `host`。
private struct HostWindowReader: NSViewRepresentable {
    let host: HostWindow

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.host = host
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) { view.host = host }

    final class ReaderView: NSView {
        var host: HostWindow?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            host?.window = window
        }

        /// 只用来取窗口，不接收鼠标。
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// 提示条的展示部分：圆形图标、标题与等宽副标题，尾部为缩略图与链接按钮。
struct ToastCardView: View {
    let content: ToastContent
    var onCopy: (CaptureItem) -> Void = { _ in }
    var onShowInFinder: (CaptureItem) -> Void = { _ in }
    var onReveal: (RevealTarget) -> Void = { _ in }
    /// 开始拖出缩略图。
    var onDragStart: () -> Void = {}

    var body: some View {
        ToastWidth {
            HStack(spacing: 10) {
                icon
                VStack(alignment: .leading, spacing: 2) {
                    Text(ToastText.title(content))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(2).truncationMode(.middle)
                    if let subtitle = ToastText.subtitle(content) {
                        Text(subtitle).tandemText(.monoMeta).foregroundStyle(Theme.textSecondary)
                            .lineLimit(3).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 8)
                // 按钮与缩略图不换行、不压缩，文字占剩下的宽度。
                HStack(spacing: 10) { trailing }.fixedSize()
            }
            .buttonStyle(TandemButtonStyle(.link))
            .floatingCard()
        }
    }

    private var icon: some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Theme.onVideo)
            .frame(width: 22, height: 22)
            .background(Circle().fill(ToastText.isError(content) ? Theme.danger : Theme.accent))
    }

    private var symbol: String {
        switch content {
        case .capture(let item, _): item.kind == .recording ? "record.circle" : "camera.fill"
        case .transfer(let notice): notice.isError ? "exclamationmark" : "checkmark"
        }
    }

    @ViewBuilder private var trailing: some View {
        switch content {
        case .capture(let item, _):
            if item.kind == .recording {
                Button("拷贝") { onCopy(item) }
            }
            Button("在 Finder 中显示") { onShowInFinder(item) }
            CaptureThumbnail(item: item)
                .frame(width: 36, height: 36)
                .onDrag {
                    // 拖出后收起；推迟到下一轮，避免在拖拽开始的回调里移除源视图。
                    Task { @MainActor in onDragStart() }
                    // 文件不存在时 contentsOf 返回 nil，给出空提供者而不是崩溃。
                    return NSItemProvider(contentsOf: item.url) ?? NSItemProvider()
                }
                .help(item.url.lastPathComponent)
        case .transfer(let notice):
            if let target = notice.revealPath {
                Button("在文件中查看") { onReveal(target) }
            }
        }
    }
}

/// 提示条宽度：按内容取宽，夹在 320–560 之间，且不超过可用宽度。
private struct ToastWidth: Layout {
    static let minWidth: CGFloat = 320
    static let maxWidth: CGFloat = 560

    private func width(_ proposal: ProposedViewSize, _ subview: LayoutSubview) -> CGFloat {
        let ideal = subview.sizeThatFits(.unspecified).width
        return min(max(ideal, Self.minWidth), Self.maxWidth, proposal.width ?? .infinity)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let width = width(proposal, subview)
        return CGSize(width: width, height: subview.sizeThatFits(ProposedViewSize(width: width, height: nil)).height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
