import DeviceCore
import SwiftUI

/// 内置助手只操作发起任务时选定的设备；切换侧栏不会改变正在执行的目标。
struct PhoneAgentSection: View {
    let services: AppServices
    let deviceID: String?

    @Environment(\.openWindow) private var openWindow
    @State private var drafts: [String: String] = [:]
    @State private var replies: [String: String] = [:]

    private var device: DeviceInfo? {
        guard let deviceID else { return nil }
        return services.model.devices.first { $0.id == deviceID } ?? services.model.lastKnownDevices[deviceID]
    }

    private var run: PhoneAgentRun? {
        guard let deviceID else { return nil }
        return services.phoneAgent.runs[deviceID]
    }

    private var isRunning: Bool { run?.status.isRunning == true }
    private var isBusy: Bool { services.phoneAgent.activeDeviceID != nil }
    private var otherDeviceIsRunning: Bool {
        if let activeID = services.phoneAgent.activeDeviceID { return activeID != deviceID }
        return false
    }

    private var goal: Binding<String> {
        Binding(
            get: { deviceID.flatMap { drafts[$0] } ?? run?.goal ?? "" },
            set: { if let deviceID { drafts[deviceID] = $0 } })
    }

    /// 顺序也决定提示优先级：先明确操作目标，再检查模型配置。
    private var unavailableMessage: String? {
        guard let deviceID else { return "在左侧选择一台设备，或先连接手机" }
        if otherDeviceIsRunning { return "另一台设备的任务正在执行，请等待完成或先停止" }
        guard services.model.devices.contains(where: { $0.id == deviceID && $0.state == .connected }) else {
            return "设备未连接，连接后即可执行任务"
        }
        if services.locks.isLocked(deviceID) { return "此设备已禁止 AI 操作，请先关闭下方开关" }
        if device?.capabilities.contains(.screenshot) != true { return "此设备暂不支持读取屏幕" }
        return services.agentSettings.readinessMessage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            VStack(alignment: .leading, spacing: Metrics.headerToCard) {
                SectionHeader("手机助手")
                VStack(alignment: .leading, spacing: 12) {
                    targetLabel
                    TextField("例如：打开设置，找到电池页面", text: goal, axis: .vertical)
                        .lineLimit(3...6)
                        .tandemField(multiline: true)
                        .disabled(deviceID == nil || isRunning || otherDeviceIsRunning)
                        .accessibilityLabel("要在手机上执行的任务")
                    actionButton
                    if !isRunning, let message = unavailableMessage {
                        Text(message)
                            .tandemText(.meta)
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if deviceID == nil {
                        Button("连接设备") { openWindow(id: "pairing") }
                            .buttonStyle(TandemButtonStyle(.secondary))
                    }
                    Text("任务、当前屏幕和应用名称会发送给所选模型")
                        .tandemText(.meta)
                        .foregroundStyle(Theme.textSecondary)
                }
                .tandemCard(padding: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            }
            if let run { progressSection(run) }
            PhoneAgentModelSection(settings: services.agentSettings, disabled: isBusy)
        }
    }

    private var targetLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "iphone")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(device?.name ?? (deviceID == nil ? "尚未选择设备" : "当前设备"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(isRunning ? "正在操作此设备" : "任务将在此设备上执行")
                    .tandemText(.meta)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var actionButton: some View {
        if isRunning {
            Button {
                services.phoneAgent.stop()
            } label: {
                Label("停止", systemImage: "stop.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(TandemButtonStyle(.secondary))
            .disabled(isStopping)
        } else {
            Button {
                guard let deviceID else { return }
                services.phoneAgent.start(goal: goal.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines), deviceID: deviceID)
            } label: {
                Label(run?.status == .needsUser ? "开始新任务" : "开始执行", systemImage: "sparkles").frame(maxWidth: .infinity)
            }
            .buttonStyle(TandemButtonStyle(.primary))
            .disabled(isBusy || unavailableMessage != nil || goal.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if otherDeviceIsRunning {
                Button("停止其他设备的任务") { services.phoneAgent.stop() }
                    .buttonStyle(TandemButtonStyle(.link))
            }
        }
    }

    private var isStopping: Bool {
        guard let run else { return false }
        if case .stopping = run.status { return true }
        return false
    }

    private func progressSection(_ run: PhoneAgentRun) -> some View {
        VStack(alignment: .leading, spacing: Metrics.headerToCard) {
            HStack(spacing: 8) {
                if run.status.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: statusSymbol(run.status)).foregroundStyle(statusColor(run.status))
                }
                Text(run.status.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                if !run.status.isRunning, let deviceID {
                    Button("清除") {
                        services.phoneAgent.clear(deviceID: deviceID)
                        replies[deviceID] = nil
                    }
                        .buttonStyle(TandemButtonStyle(.link))
                }
            }
            if !run.status.isRunning {
                Text("任务：\(run.goal)")
                    .tandemText(.meta)
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !run.message.isEmpty {
                Text(run.message)
                    .tandemText(.body)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let deviceID, services.phoneAgent.canResume(deviceID: deviceID) {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("补充信息或回答上面的问题", text: Binding(
                        get: { replies[deviceID] ?? "" }, set: { replies[deviceID] = $0 }), axis: .vertical)
                        .lineLimit(2...4)
                        .tandemField(multiline: true)
                        .disabled(isBusy)
                        .accessibilityLabel("给手机助手的补充信息")
                    Text("若已在手机上完成所需操作，可留空后继续；助手会重新读取当前画面。")
                        .tandemText(.meta)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        services.phoneAgent.resume(deviceID: deviceID, reply: replies[deviceID] ?? "")
                        replies[deviceID] = nil
                    } label: {
                        Label("继续执行", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(TandemButtonStyle(.primary))
                    .disabled(isBusy || unavailableMessage != nil)
                }
            }
            if !run.steps.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(run.steps) { step in
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.tool)
                                    .tandemText(.monoMeta)
                                    .foregroundStyle(Theme.textSecondary)
                                if let planning = step.planningSeconds, let execution = step.executionSeconds {
                                    Text("模型 \(planning, specifier: "%.1f") 秒 · 操作 \(execution, specifier: "%.1f") 秒")
                                        .tandemText(.meta)
                                        .foregroundStyle(Theme.textSecondary)
                                }
                                if !step.result.isEmpty {
                                    Text(step.result)
                                        .tandemText(.meta)
                                        .foregroundStyle(Theme.textSecondary)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(.top, 4)
                        } label: {
                            Text("\(step.number). \(step.summary)")
                                .tandemText(.body)
                                .foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .tandemCard(padding: EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            }
        }
    }

    private func statusSymbol(_ status: PhoneAgentStatus) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .needsUser: "hand.raised.fill"
        default: "circle.dotted"
        }
    }

    private func statusColor(_ status: PhoneAgentStatus) -> Color {
        switch status {
        case .completed: Theme.success
        case .failed: Theme.danger
        case .needsUser: Theme.warning
        default: Theme.textSecondary
        }
    }
}

/// 配置默认折叠，缺少配置时展开；API Key 仅通过 SecureField 编辑并显式写入钥匙串。
private struct PhoneAgentModelSection: View {
    let settings: PhoneAgentSettings
    let disabled: Bool

    @State private var expanded = false
    @State private var apiKeyDraft = ""
    @State private var keyMessage: String?
    @State private var keySaveFailed = false

    var body: some View {
        @Bindable var settings = settings
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                Picker("模型来源", selection: $settings.provider) {
                    Text(PhoneAgentProvider.codex.title).tag(PhoneAgentProvider.codex)
                    Text(PhoneAgentProvider.openAICompatible.title).tag(PhoneAgentProvider.openAICompatible)
                }
                .pickerStyle(.menu)
                if settings.provider == .codex {
                    Text("复用这台 Mac 上 Codex 的登录状态")
                        .tandemText(.meta)
                        .foregroundStyle(Theme.textSecondary)
                    settingField("模型", placeholder: "例如 gpt-6.1-sol", text: $settings.codexModel)
                    settingField("Codex 可执行文件", placeholder: "/opt/homebrew/bin/codex", text: $settings.codexPath)
                } else {
                    settingField("API 地址", placeholder: "https://api.example.com/v1", text: $settings.baseURL)
                    settingField("模型", placeholder: "支持图片和结构化输出的模型", text: $settings.apiModel)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("API Key").tandemText(.meta).foregroundStyle(Theme.textSecondary)
                        SecureField("仅保存在本机钥匙串", text: $apiKeyDraft)
                            .tandemField()
                            .accessibilityLabel("API Key")
                            .onChange(of: apiKeyDraft) { _, _ in keyMessage = nil }
                        Button("保存 API Key", action: saveKey)
                            .buttonStyle(TandemButtonStyle(.secondary))
                        if let keyMessage {
                            Text(keyMessage)
                                .tandemText(.meta)
                                .foregroundStyle(keySaveFailed ? Theme.danger : Theme.success)
                        }
                    }
                }
                if let message = settings.readinessMessage {
                    Text(message)
                        .tandemText(.meta)
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(disabled)
            .padding(.top, Metrics.headerToCard)
        } label: {
            HStack(spacing: 6) {
                Text("模型")
                    .tandemText(.body)
                    .foregroundStyle(Theme.textPrimary)
                Text(settings.provider.title)
                    .tandemText(.meta)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .onAppear {
            apiKeyDraft = settings.apiKey
            expanded = settings.readinessMessage != nil
        }
    }

    private func settingField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).tandemText(.meta).foregroundStyle(Theme.textSecondary)
            TextField(placeholder, text: text)
                .tandemField()
                .accessibilityLabel(title)
        }
    }

    private func saveKey() {
        do {
            try settings.saveAPIKey(apiKeyDraft)
            keySaveFailed = false
            keyMessage = apiKeyDraft.isEmpty ? "已移除本机 API Key" : "API Key 已保存到本机钥匙串"
        } catch {
            keySaveFailed = true
            keyMessage = "API Key 保存失败，请重试"
        }
    }
}
