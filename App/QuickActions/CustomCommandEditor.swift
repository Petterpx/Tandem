import SwiftUI

/// 添加或修改一条自定义命令：名称与命令两个输入框；去掉首尾空白后任一为空时不能保存。
struct CustomCommandEditor: View {
    let original: CustomCommand?
    let onSave: (_ name: String, _ command: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var command: String

    init(original: CustomCommand?, onSave: @escaping (_ name: String, _ command: String) -> Void) {
        self.original = original
        self.onSave = onSave
        _name = State(initialValue: original?.name ?? "")
        _command = State(initialValue: original?.command ?? "")
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedCommand: String { command.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { !trimmedName.isEmpty && !trimmedCommand.isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(original == nil ? "添加命令" : "修改命令").font(.headline)
            field("名称") {
                TextField("例如：重启 SystemUI", text: $name)
            }
            field("命令（在 adb shell 中执行）") {
                TextField("例如：pkill -f com.android.systemui", text: $command, axis: .vertical)
                    .font(.body.monospaced())
                    .lineLimit(3...8)
            }
            Text("可用 {package} 表示「应用」分段选中的包名")
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(trimmedName, trimmedCommand)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 420)
    }

    private func field(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.textSecondary)
            content()
        }
    }
}
