import SwiftUI

/// 窗口底部的截图 / 录屏提示条：读取 `toasts.current[origin]`，8 秒后消失，悬停时暂停。
struct CaptureToastView: View {
    let toasts: ToastCenter
    let store: CaptureStore
    let origin: ToastOrigin
    /// 「在文件中查看」：由调用方接到文件页（Task 13）。
    var onReveal: (RevealTarget) -> Void = { _ in }

    var body: some View {
        if let toast = toasts.current[origin] {
            ToastCard(toast: toast, store: store, onReveal: onReveal) { toasts.dismiss(toast.id, in: origin) }
                .id(toast.id)
                .padding(12)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

private struct ToastCard: View {
    let toast: CaptureToast
    let store: CaptureStore
    let onReveal: (RevealTarget) -> Void
    let dismiss: () -> Void

    @State private var hovering = false

    /// 计时任务的标识：悬停状态变化时重新开始计时。
    private struct TimerKey: Equatable {
        let id: UUID
        let hovering: Bool
    }

    var body: some View {
        card
            .buttonStyle(.borderless)
            .foregroundStyle(Theme.accent)
            .padding(10)
            .frame(maxWidth: 520)
            .background(Theme.panel)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isError ? Theme.danger : Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .onHover { hovering = $0 }
            .task(id: TimerKey(id: toast.id, hovering: hovering)) {
                guard !hovering else { return }
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                dismiss()
            }
    }

    private var isError: Bool {
        if case .transfer(let notice) = toast.content { return notice.isError }
        return false
    }

    @ViewBuilder private var card: some View {
        switch toast.content {
        case .capture(let item, let note): captureCard(item, note: note)
        case .transfer(let notice): transferCard(notice)
        }
    }

    private func transferCard(_ notice: TransferNotice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(notice.isError ? Theme.danger : Theme.success)
            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title).font(.callout.weight(.medium))
                    .foregroundStyle(notice.isError ? Theme.danger : Theme.textPrimary)
                    .lineLimit(2).truncationMode(.middle)
                if let detail = notice.detail {
                    Text(detail).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(3)
                }
            }
            Spacer(minLength: 8)
            if let target = notice.revealPath {
                Button("在文件中查看") { onReveal(target) }
            }
        }
    }

    private func captureCard(_ item: CaptureItem, note: String?) -> some View {
        HStack(spacing: 12) {
            CaptureThumbnail(item: item).frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 3) {
                if let note {
                    Text(note).font(.callout.weight(.medium)).foregroundStyle(Theme.textPrimary)
                }
                if item.kind == .recording {
                    Text("\(CaptureButtons.clock(item.duration ?? 0)) · \(Self.sizeText(item.fileSize))")
                        .font(.callout).foregroundStyle(Theme.textPrimary)
                } else if note == nil {
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
    }

    private static func sizeText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
