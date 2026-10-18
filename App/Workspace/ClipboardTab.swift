import DeviceCore
import SwiftUI

/// 「剪贴板」标签（spec §7）：预览、读 / 写按钮、输入框、历史、双向自动同步开关。
struct ClipboardTab: View {
    let commands: DeviceCommands
    let clipboard: ClipboardService
    let deviceID: String

    @State private var input = ""
    /// Mac 剪贴板文本：出现时读取，之后每 0.5 秒刷新。
    @State private var macText: String?

    private var supported: Bool { commands.can(.clipboard, deviceID) }
    private var source: WriteSource { ClipboardService.writeSource(input: input, macText: macText) }
    private var sourceLabel: String {
        switch source {
        case .input: "（输入框）"
        case .macClipboard, .unavailable: "（Mac 剪贴板）"
        }
    }

    var body: some View {
        Group {
            if supported { content } else {
                Text("该设备不支持剪贴板")
                    .font(.callout)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                Text(clipboard.preview[deviceID] ?? "")
                    .textSelection(.enabled)
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 70)
            .padding(6)
            .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 6))

            Button("读取") { Task { await commands.readClipboard(deviceID) } }
                .controlSize(.small)

            TextEditor(text: $input)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)
                .scrollContentBackground(.hidden)
                .frame(height: 60)
                .padding(4)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("写入\(sourceLabel)") { Task { await commands.writeClipboard(deviceID, input: input, paste: false) } }
                Button("写入并粘贴\(sourceLabel)") { Task { await commands.writeClipboard(deviceID, input: input, paste: true) } }
            }
            .controlSize(.small)
            .disabled(source == .unavailable)
            .modifier(UnavailableHelp(unavailable: source == .unavailable))

            Text("历史").font(.caption).foregroundStyle(Theme.textSecondary)
            List(clipboard.history[deviceID] ?? []) { record in
                HistoryRow(record: record, onRewrite: {
                    Task { await commands.writeClipboard(deviceID, input: record.text, paste: false) }
                }, onCopy: { clipboard.copyToMac(record.text) })
                .listRowBackground(Theme.panel)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)

            Toggle("双向自动同步", isOn: Binding(
                get: { clipboard.isSyncEnabled(deviceID) },
                set: { commands.setClipboardSync(deviceID, $0) }))
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)
        }
        .padding(12)
        .task {
            // 标签可见期间轮询 Mac 剪贴板，离开时任务随之取消
            while !Task.isCancelled {
                macText = clipboard.macText
                try? await Task.sleep(for: ClipboardService.pollInterval)
            }
        }
    }
}

/// 仅在没有可写文本时挂上提示，避免空的 help。
private struct UnavailableHelp: ViewModifier {
    let unavailable: Bool

    func body(content: Content) -> some View {
        if unavailable { content.help("Mac 剪贴板中没有文本") } else { content }
    }
}

private struct HistoryRow: View {
    let record: ClipboardRecord
    let onRewrite: () -> Void
    let onCopy: () -> Void

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private var directionLabel: String {
        switch record.direction {
        case .read: "读"
        case .write: "写"
        case .sync: "同步"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(directionLabel).foregroundStyle(Theme.accent)
                Text(Self.time.string(from: record.date)).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("再次写入", action: onRewrite)
                Button("复制到 Mac", action: onCopy)
            }
            .font(.caption)
            .buttonStyle(.borderless)
            Text(record.text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "")
                .lineLimit(1)
                .font(.callout)
                .foregroundStyle(Theme.textPrimary)
        }
    }
}
