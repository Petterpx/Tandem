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
            toolbar
            if commands.isEmpty {
                Text("还没有命令。例如：名称「重启 SystemUI」，命令 `pkill -f com.android.systemui`；命令里可用 {package} 表示目标 App 的包名。")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if editing {
                editList
            } else {
                ForEach(commands) { c in
                    commandRow(c)
                }
            }
        }
        .font(.callout)
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

    private var toolbar: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("添加") { editor = EditorRequest(command: nil) }
            if !commands.isEmpty {
                Button(editing ? "完成" : "编辑") { editing.toggle() }
            }
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }

    // MARK: 执行

    /// 含 `{package}` 且没有目标包名时不可执行的原因。
    private func unavailableReason(_ c: CustomCommand) -> String? {
        guard c.needsPackage, package == nil else { return nil }
        return model.isReadingForeground(deviceID) ? "正在读取前台 App" : "请先在「应用」分段选择目标"
    }

    private func commandRow(_ c: CustomCommand) -> some View {
        let running = model.isRunning(deviceID, c.id)
        let reason = unavailableReason(c)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button(c.name) { run(c) }
                    .controlSize(.small)
                    .disabled(running || reason != nil)
                    .help(reason ?? c.command)
                if running { ProgressView().controlSize(.small) }
            }
            if let output = model.output(deviceID, c.id) {
                OutputBox(output: output)
            }
        }
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
                            .font(.caption.monospaced())
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
                .buttonStyle(.borderless)
                .foregroundStyle(Theme.textSecondary)
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

/// 命令输出：标题行（失败时标红并显示退出码或超时）、「拷贝」，下面是等宽、最多 200 行的输出。
private struct OutputBox: View {
    let output: CommandOutput

    /// 估算的每行高度，用来让输出框贴合内容（最多约 12 行，超出滚动）。
    private static let lineHeight: CGFloat = 14

    private var failure: String? { output.failure }

    var body: some View {
        let shown = output.text
        let lines = max(1, shown.split(separator: "\n", omittingEmptySubsequences: false).count)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(failure ?? "输出")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(failure == nil ? Theme.textSecondary : Theme.danger)
                Spacer()
                Button("拷贝") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(shown, forType: .string)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .disabled(shown.isEmpty)
            }
            ScrollView([.vertical, .horizontal]) {
                Text(shown.isEmpty ? "（无输出）" : shown)
                    .font(.caption.monospaced())
                    .foregroundStyle(shown.isEmpty ? Theme.textSecondary : Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(height: min(CGFloat(lines), 12) * Self.lineHeight + 4)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.canvas))
    }
}
