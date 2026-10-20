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
            Text(original == nil ? "添加命令" : "修改命令").tandemText(.headerTitle).foregroundStyle(Theme.textPrimary)
            field("名称") {
                TextField("例如：重启 SystemUI", text: $name)
                    .tandemField()
            }
            field("命令（在 adb shell 中执行）") {
                TextField("例如：pkill -f com.android.systemui", text: $command, axis: .vertical)
                    .lineLimit(3...8)
                    .tandemField(mono: true, multiline: true)
            }
            Text("可用 {package} 表示「应用」分段选中的包名")
                .tandemText(.meta)
                .foregroundStyle(Theme.textSecondary)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(TandemButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button("保存") {
                    onSave(trimmedName, trimmedCommand)
                    dismiss()
                }
                .buttonStyle(TandemButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func field(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).tandemText(.meta).foregroundStyle(Theme.textSecondary)
            content()
        }
    }
}
