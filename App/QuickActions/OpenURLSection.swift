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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                TextField("https:// 或 scheme://", text: $input)
                    .tandemField(mono: true)
                    .onSubmit(openInput)
                if busy { ProgressView().controlSize(.small) }
                Button("打开", action: openInput)
                    .buttonStyle(TandemButtonStyle(.primary))
                    .disabled(!canOpen)
            }
            FlowLayout {
                ForEach(model.store.urlHistory, id: \.self) { url in
                    HistoryChip(url: url, disabled: busy, onOpen: { open(url) }, onRemove: { model.store.removeURL(url) })
                }
            }
        }
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

/// 一条链接历史：胶囊按钮，点击打开，右键删除。
private struct HistoryChip: View {
    let url: String
    let disabled: Bool
    let onOpen: () -> Void
    let onRemove: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        Button(action: onOpen) {
            Text(url)
                .tandemText(.monoMeta)
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 9)
                .frame(maxWidth: 300, minHeight: 24, maxHeight: 24)
                .background(shape.fill(Theme.card))
                .overlay(shape.strokeBorder(Theme.border, lineWidth: 1))
                .contentShape(shape)
        }
        .buttonStyle(TandemButtonStyle(.link, tint: Theme.textTertiary))
        .disabled(disabled)
        .help(url)
        .contextMenu { Button("删除", action: onRemove) }
    }
}
