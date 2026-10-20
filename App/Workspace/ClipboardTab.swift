import DeviceCore
import SwiftUI

extension ClipboardDirection {
    var chipTitle: String {
        switch self {
        case .read: "读"
        case .write: "写"
        case .sync: "同步"
        }
    }

    var chipTone: ChipTone {
        self == .read ? .accent : .neutral
    }
}

/// 「剪贴板」标签（spec §7）：读取预览、写入、最近记录、双向自动同步开关。
struct ClipboardTab: View {
    let commands: DeviceCommands
    let clipboard: ClipboardService
    let deviceID: String

    @State private var input = ""
    /// Mac 剪贴板文本：出现时读取，之后每 0.5 秒刷新。
    @State private var macText: String?

    private var supported: Bool { commands.can(.clipboard, deviceID) }

    static func syncSubtitle(on: Bool) -> String {
        on ? "已开启：Mac 与手机剪贴板实时同步" : "默认关闭，需要时手动读取或写入"
    }

    var body: some View {
        Group {
            if supported {
                ScrollView {
                    ClipboardTabContent(commands: commands, clipboard: clipboard, deviceID: deviceID, input: $input, macText: macText)
                }
                .task {
                    // 标签可见期间轮询 Mac 剪贴板，离开时任务随之取消
                    while !Task.isCancelled {
                        macText = clipboard.macText
                        try? await Task.sleep(for: ClipboardService.pollInterval)
                    }
                }
            } else {
                Text("该设备不支持剪贴板")
                    .tandemText(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// 标签正文（ScrollView 里面的部分），单独拆出来供快照渲染。
struct ClipboardTabContent: View {
    let commands: DeviceCommands
    let clipboard: ClipboardService
    let deviceID: String
    @Binding var input: String
    let macText: String?

    private var source: WriteSource { ClipboardService.writeSource(input: input, macText: macText) }
    private var preview: String { clipboard.preview[deviceID] ?? "" }

    private var placeholder: String {
        guard let macText, let first = macText.split(separator: "\n", omittingEmptySubsequences: false).first, !first.isEmpty else {
            return "输入要写入的文本"
        }
        return String(first)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            readSection
            writeSection
            historySection
            syncSection
            fileSection
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 20, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var readSection: some View {
        VStack(alignment: .leading, spacing: Metrics.headerToCard) {
            SectionHeader("读取")
            Button("读取手机剪贴板") { Task { await commands.readClipboard(deviceID) } }
                .buttonStyle(TandemButtonStyle(.secondary))
            if !preview.isEmpty {
                let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius)
                VStack(alignment: .leading, spacing: 4) {
                    Text("手机剪贴板内容（已复制到 Mac）")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accentStrong)
                    Text(preview)
                        .tandemText(.mono)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11))
                .background(shape.fill(Theme.accentTint))
                .overlay(shape.strokeBorder(Theme.accentTintBorder, lineWidth: 1))
            }
        }
    }

    private var writeSection: some View {
        VStack(alignment: .leading, spacing: Metrics.headerToCard) {
            SectionHeader("写入（默认填入 Mac 剪贴板内容）")
            TextField("", text: $input, prompt: Text(placeholder), axis: .vertical)
                .lineLimit(1...4)
                .tandemField(multiline: true)
            HStack(spacing: 8) {
                Button { Task { await commands.writeClipboard(deviceID, input: input, paste: false) } } label: {
                    Text("写入").frame(maxWidth: .infinity)
                }
                .buttonStyle(TandemButtonStyle(.secondary))
                Button { Task { await commands.writeClipboard(deviceID, input: input, paste: true) } } label: {
                    Text("写入并粘贴").frame(maxWidth: .infinity)
                }
                .buttonStyle(TandemButtonStyle(.primary))
            }
            .disabled(source == .unavailable)
            .modifier(UnavailableHelp(unavailable: source == .unavailable))
        }
    }

    @ViewBuilder private var historySection: some View {
        let records = clipboard.history[deviceID] ?? []
        VStack(alignment: .leading, spacing: Metrics.headerToCard) {
            SectionHeader("最近记录（点击再次写入）")
            if !records.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                        HistoryRow(record: record, onRewrite: {
                            Task { await commands.writeClipboard(deviceID, input: record.text, paste: false) }
                        }, onCopy: { clipboard.copyToMac(record.text) })
                        // 行间 1 px 分隔线，最后一行之后不加
                        if index < records.count - 1 { CardDivider() }
                    }
                }
                .tandemCard(padding: EdgeInsets())
            }
        }
    }

    private var syncSection: some View {
        let on = clipboard.isSyncEnabled(deviceID)
        return VStack(spacing: 0) {
            CardRow("双向自动同步", subtitle: ClipboardTab.syncSubtitle(on: on)) {
                Toggle("双向自动同步", isOn: Binding(
                    get: { clipboard.isSyncEnabled(deviceID) },
                    set: { commands.setClipboardSync(deviceID, $0) }))
                    .labelsHidden()
                    .toggleStyle(TandemSwitchStyle())
            }
        }
        .tandemCard()
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: Metrics.headerToCard) {
            SectionHeader("文件")
            Text("在投屏上按 ⌘V 时，按 Mac 剪贴板里的文件推送到设备")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
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

    @State private var hovered = false

    var body: some View {
        Button(action: onRewrite) {
            HStack(spacing: 8) {
                Chip(record.direction.chipTitle, tone: record.direction.chipTone)
                Text(record.text.split(separator: "\n", omittingEmptySubsequences: false).first.map(String.init) ?? "")
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .tandemText(.body)
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? Theme.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
        .onHover { hovered = $0 }
        .contextMenu { Button("复制到 Mac", action: onCopy) }
    }
}

/// 记录行用的无样式按钮：保留整行点击，不套系统外观。
private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
