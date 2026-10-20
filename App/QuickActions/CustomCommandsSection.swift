import AppKit
import DeviceCore
import SwiftUI

/// 自定义命令分段（spec §3.8）：每条命令一个按钮，最近一次输出显示在按钮下方；「编辑」切换为可排序、删除的列表。
struct CustomCommandsSection: View {
    let model: QuickActionsModel
    let deviceID: String

    @State private var editing = false
    @State private var editor: EditorRequest?

    private var commands: [CustomCommand] { model.store.commands }
    private var package: String? { model.targetPackage(deviceID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if commands.isEmpty {
                Text("还没有命令。例如：名称「重启 SystemUI」，命令 `pkill -f com.android.systemui`；命令里可用 {package} 表示目标 App 的包名。")
                    .tandemText(.meta)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if editing, !commands.isEmpty {
                editList
                toolbar
            } else {
                FlowLayout {
                    ForEach(commands) { c in commandButton(c) }
                    addButton
                    if !commands.isEmpty { editToggle }
                }
            }
            if !editing {
                ForEach(commands) { c in
                    if let output = model.output(deviceID, c.id) {
                        OutputBox(title: c.name, output: output)
                    }
                }
            }
        }
        // 删光后退出编辑模式，下次添加回到按钮列表
        .onChange(of: commands.isEmpty) { _, empty in if empty { editing = false } }
        .sheet(item: $editor) { request in
            CustomCommandEditor(original: request.command) { name, command in
                if let original = request.command {
                    model.store.updateCommand(CustomCommand(id: original.id, name: name, command: command))
                } else {
                    model.store.addCommand(name: name, command: command)
                }
            }
        }
    }

    private var addButton: some View {
        Button("+ 添加") { editor = EditorRequest(command: nil) }
            .buttonStyle(TandemButtonStyle(.secondary))
    }

    private var editToggle: some View {
        Button(editing ? "完成" : "编辑") { editing.toggle() }
            .buttonStyle(TandemButtonStyle(.link))
            .frame(height: Metrics.buttonHeight)
    }

    /// 编辑模式下列表下方：「+ 添加」与「完成」。
    private var toolbar: some View {
        HStack(spacing: 10) {
            addButton
            editToggle
        }
    }

    // MARK: 执行

    /// 含 `{package}` 且没有目标包名时不可执行的原因。
    private func unavailableReason(_ c: CustomCommand) -> String? {
        guard c.needsPackage, package == nil else { return nil }
        return model.isReadingForeground(deviceID) ? "正在读取前台 App" : "请先在「应用」分段选择目标"
    }

    private func commandButton(_ c: CustomCommand) -> some View {
        let running = model.isRunning(deviceID, c.id)
        let reason = unavailableReason(c)
        return Button { run(c) } label: {
            HStack(spacing: 5) {
                if running { ProgressView().controlSize(.small) }
                Text(c.name)
            }
        }
        .buttonStyle(TandemButtonStyle(.secondary))
        .disabled(running || reason != nil)
        .help(reason ?? c.command)
    }

    private func run(_ c: CustomCommand) {
        let id = deviceID, package = package
        Task { await model.runCustom(id, c, package: package) }
    }

    // MARK: 编辑

    /// 编辑列表：拖动排序、修改、删除。放在外层 ScrollView 里，高度按行数给定。
    private var editList: some View {
        List {
            ForEach(commands) { c in
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).foregroundStyle(Theme.textPrimary).lineLimit(1)
                        Text(c.command)
                            .tandemText(.monoMeta)
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer()
                    Button { editor = EditorRequest(command: c) } label: { Image(systemName: "pencil") }
                        .help("修改")
                    Button { model.removeCommand(c.id) } label: { Image(systemName: "trash") }
                        .help("删除")
                }
                .buttonStyle(TandemButtonStyle(.ghostIcon))
            }
            .onMove { model.store.moveCommands(from: $0, to: $1) }
            .onDelete { offsets in
                offsets.map { commands[$0].id }.forEach(model.removeCommand)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(height: min(CGFloat(commands.count) * 40, 320))
    }
}

/// 打开编辑器的请求：`command` 为 nil 表示添加。
private struct EditorRequest: Identifiable {
    let id = UUID()
    let command: CustomCommand?
}

/// 命令输出：标题行（命令名；失败时标红并显示退出码或超时）、「拷贝」，下面是等宽、最多 200 行的输出。
private struct OutputBox: View {
    let title: String
    let output: CommandOutput

    /// 估算的每行高度，用来让输出框贴合内容（最多约 12 行，超出滚动）。
    private static let lineHeight: CGFloat = 15

    private var failure: String? { output.failure }

    var body: some View {
        let shown = output.text
        let lines = max(1, shown.split(separator: "\n", omittingEmptySubsequences: false).count)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(failure.map { "\(title) · \($0)" } ?? "\(title) · 输出")
                    .tandemText(.meta)
                    .foregroundStyle(failure == nil ? Theme.textSecondary : Theme.danger)
                    .lineLimit(1)
                Spacer()
                Button("拷贝") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(shown, forType: .string)
                }
                .buttonStyle(TandemButtonStyle(.link))
                .disabled(shown.isEmpty)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(shown.isEmpty ? "（无输出）" : shown)
                    .tandemText(.mono)
                    .foregroundStyle(shown.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: min(CGFloat(lines), 12) * Self.lineHeight + 4)
        }
        .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.controlHover))
    }
}
