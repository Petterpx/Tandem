import SwiftUI
import IOSSimulatorDriver

/// 本机模拟器入口：枚举全部可用设备，启动后交给 AppModel 选中并建立会话。
struct SimulatorPicker: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var submitting = false

    private var busy: Bool { submitting || model.bootingSimulatorID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("iOS 模拟器").tandemText(.headerTitle).foregroundStyle(Theme.textPrimary)
                Spacer()
                Button("刷新") { Task { await model.refreshSimulators() } }
                    .buttonStyle(TandemButtonStyle(.secondary))
                    .disabled(model.simulatorLoading || busy)
            }

            Text("选择本机 Xcode 中的模拟器，启动后在 Tandem 中控制。")
                .tandemText(.body).foregroundStyle(Theme.textSecondary)

            if let error = model.simulatorError {
                Text(error).tandemText(.body).foregroundStyle(Theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            if model.simulatorLoading {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在读取模拟器…").tandemText(.body).foregroundStyle(Theme.textSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.simulatorDevices.isEmpty {
                empty
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(model.simulatorDevices) { device in row(device) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(TandemButtonStyle(.secondary))
                    .disabled(busy)
            }
        }
        .padding(20)
        .frame(width: 520, height: 440)
        .background(Theme.windowBackground)
        .interactiveDismissDisabled(busy)
        .task { await model.refreshSimulators() }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Text("未找到可用的 iOS 模拟器")
                .tandemText(.body).foregroundStyle(Theme.textPrimary)
            Text("请先在 Xcode 设置中安装 iOS 模拟器运行时，并在 Window → Devices and Simulators 中创建模拟器，然后刷新。")
                .tandemText(.meta).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ device: SimulatorDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone").foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name).tandemText(.body).foregroundStyle(Theme.textPrimary)
                Text("\(runtimeName(device.runtime)) · \(device.isBooted ? "已启动" : "未启动")")
                    .tandemText(.meta).foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 8)
            if model.bootingSimulatorID == device.id {
                ProgressView().controlSize(.small)
            }
            Button(device.isBooted ? "连接" : "启动") { connect(device) }
                .buttonStyle(TandemButtonStyle(.primary))
                .disabled(busy || model.simulatorLoading)
        }
        .tandemCard(padding: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
    }

    private func connect(_ device: SimulatorDevice) {
        guard !busy else { return }
        submitting = true
        Task { @MainActor in
            defer { submitting = false }
            await model.bootSimulator(device)
            if model.simulatorError == nil { dismiss() }
        }
    }

    private func runtimeName(_ identifier: String) -> String {
        let name = identifier.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
        let parts = name.split(separator: "-")
        guard let platform = parts.first, parts.count > 1 else { return name }
        return "\(platform) \(parts.dropFirst().joined(separator: "."))"
    }
}
