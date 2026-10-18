import SwiftUI

/// 窗口底部的截图 / 录屏提示条：读取 `toasts.current[origin]`，8 秒后消失，悬停时暂停。
struct CaptureToastView: View {
    let toasts: ToastCenter
    let store: CaptureStore
    let origin: ToastOrigin

    var body: some View {
        if let toast = toasts.current[origin] {
            ToastCard(toast: toast, store: store) { toasts.dismiss(toast.id, in: origin) }
                .id(toast.id)
                .padding(12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct ToastCard: View {
    let toast: CaptureToast
    let store: CaptureStore
    let dismiss: () -> Void

    @State private var hovering = false

    /// 计时任务的标识：悬停状态变化时重新开始计时。
    private struct TimerKey: Equatable {
        let id: UUID
        let hovering: Bool
    }

    var body: some View {
        let item = toast.item
        HStack(spacing: 12) {
            CaptureThumbnail(item: item).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                if let note = toast.note {
                    Text(note).font(.callout.weight(.medium)).foregroundStyle(Theme.textPrimary)
                }
                if item.kind == .recording {
                    Text("\(CaptureButtons.clock(item.duration ?? 0)) · \(Self.sizeText(item.fileSize))")
                        .font(.callout).foregroundStyle(Theme.textPrimary)
                } else if toast.note == nil {
                    Text("已截图").font(.callout.weight(.medium)).foregroundStyle(Theme.textPrimary)
                }
                Text(item.url.lastPathComponent)
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if item.kind == .recording {
                Button("拷贝") { store.copy(item) }
            }
            Button("在 Finder 中显示") { store.reveal(item) }
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Theme.accent)
        .padding(10)
        .frame(maxWidth: 520)
        .background(Theme.panel)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.separator, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovering = $0 }
        .task(id: TimerKey(id: toast.id, hovering: hovering)) {
            guard !hovering else { return }
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            dismiss()
        }
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
