import Foundation
import Observation

/// 提示条出现的位置：工作区窗口，或某台设备的弹出窗口（逻辑设备 id）。
enum ToastOrigin: Hashable {
    case workspace
    case popup(String)
}

struct CaptureToast: Identifiable, Equatable {
    let id: UUID
    let item: CaptureItem
    let note: String?
}

/// 每个位置一条提示；新提示直接替换旧提示。
@MainActor @Observable
final class ToastCenter {
    private(set) var current: [ToastOrigin: CaptureToast] = [:]

    func show(_ item: CaptureItem, note: String?, in origin: ToastOrigin) {
        current[origin] = CaptureToast(id: UUID(), item: item, note: note)
    }

    /// 只在该位置当前的提示仍是这个 id 时才移除，避免旧计时器误关新提示。
    func dismiss(_ id: UUID, in origin: ToastOrigin) {
        if current[origin]?.id == id { current[origin] = nil }
    }
}
