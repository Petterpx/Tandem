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

    func show(_ item: CaptureItem, note: String?, in origin: ToastOrigin) {
        current[origin] = CaptureToast(id: UUID(), content: .capture(item, note: note))
    }

    func show(_ notice: TransferNotice, in origin: ToastOrigin) {
        current[origin] = CaptureToast(id: UUID(), content: .transfer(notice))
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
