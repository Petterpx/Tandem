import Foundation
import Observation

/// 提示条出现的位置：工作区窗口，或某台设备的弹出窗口（逻辑设备 id）。
enum ToastOrigin: Hashable {
    case workspace
    case popup(String)
}

/// 提示条内容：截图 / 录屏结果，或传输结果。
enum ToastContent: Equatable {
    case capture(CaptureItem, note: String?)
    case transfer(TransferNotice)
}

struct CaptureToast: Identifiable, Equatable {
    let id: UUID
    let content: ToastContent
    /// 发出时间：第一次显示时距此已超过倒计时时长的提示条不再显示。
    let postedAt: ContinuousClock.Instant

    /// 截图 / 录屏提示的附注；传输提示为 nil。
    var note: String? {
        if case .capture(_, let note) = content { return note }
        return nil
    }
}

/// 每个位置一条提示；新提示直接替换旧提示。
@MainActor @Observable
final class ToastCenter {
    private(set) var current: [ToastOrigin: CaptureToast] = [:]

    func show(_ item: CaptureItem, note: String?, in origin: ToastOrigin, at now: ContinuousClock.Instant = .now) {
        current[origin] = CaptureToast(id: UUID(), content: .capture(item, note: note), postedAt: now)
    }

    func show(_ notice: TransferNotice, in origin: ToastOrigin, at now: ContinuousClock.Instant = .now) {
        current[origin] = CaptureToast(id: UUID(), content: .transfer(notice), postedAt: now)
    }

    /// 提示条视图出现时调用（视图消失即收起，所以每条最多出现一次）。
    /// 发出后当时没有宿主（例如未选中设备、弹出窗口已关）、过了倒计时时长才出现的，直接收起并返回 false。
    func beginShowing(_ id: UUID, in origin: ToastOrigin, at now: ContinuousClock.Instant) -> Bool {
        guard let toast = current[origin], toast.id == id else { return false }
        if now - toast.postedAt > ToastCountdown.total {
            current[origin] = nil
            return false
        }
        return true
    }

    /// 只在该位置当前的提示仍是这个 id 时才移除，避免旧计时器误关新提示。
    func dismiss(_ id: UUID, in origin: ToastOrigin) {
        if current[origin]?.id == id { current[origin] = nil }
    }

    /// 提示条上的动作（拷贝、在 Finder 中显示、在文件中查看、拖出缩略图）：先执行，再立即收起。
    func performAndDismiss(_ id: UUID, in origin: ToastOrigin, action: () -> Void) {
        action()
        dismiss(id, in: origin)
    }
}
