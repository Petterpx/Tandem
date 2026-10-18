import DeviceCore
import SwiftUI

/// 打开链接分段（spec §3.5）：输入框加「打开」，回车同样打开；下方是最近 20 条历史（所有设备共用）。
struct OpenURLSection: View {
    let model: QuickActionsModel
    let deviceID: String

    @State private var input = ""

    private var busy: Bool { model.isBusy(deviceID, .openURL) }
    private var canOpen: Bool { !busy && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("https:// 或 scheme://", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(openInput)
                Button("打开", action: openInput)
                    .disabled(!canOpen)
                if busy { ProgressView().controlSize(.small) }
            }
            .controlSize(.small)
            ForEach(model.store.urlHistory, id: \.self) { url in
                HistoryRow(url: url, disabled: busy, onOpen: { open(url) }, onRemove: { model.store.removeURL(url) })
            }
        }
        .font(.callout)
    }

    private func openInput() {
        guard canOpen else { return }
        let id = deviceID, url = input
        Task {
            // 成功后清空输入框；失败保留，便于修改后重试
            if await model.openURL(id, url), input == url { input = "" }
        }
    }

    private func open(_ url: String) {
        let id = deviceID
        Task { await model.openURL(id, url) }
    }
}

/// 一条链接历史：点击打开，悬停时出现删除按钮。
private struct HistoryRow: View {
    let url: String
    let disabled: Bool
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onOpen) {
                Text(url)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(disabled)
            .help(url)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.borderless)
            .help("删除")
            .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
    }
}
