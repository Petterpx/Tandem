import DeviceCore
import SwiftUI

/// 「AI」标签（spec §5.4）：连接状态、接入 Claude Code、当前设备的「禁止 AI 操作」。
/// 前两节是全局的，未选设备时也显示。
struct AITab: View {
    let services: AppServices
    let deviceID: String?

    static func lockSubtitle(locked: Bool) -> String {
        locked ? "已锁定：操作类工具返回 AI_LOCKED" : "锁定后截图、UI 树、日志仍可用"
    }

    var body: some View {
        ScrollView { AITabContent(services: services, deviceID: deviceID) }
    }
}

/// 标签正文（ScrollView 里面的部分），单独拆出来供快照渲染。
struct AITabContent: View {
    let services: AppServices
    let deviceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
            ConnectionSection(server: services.server, pasteboard: services.pasteboard)
            SetupSection(pasteboard: services.pasteboard)
            if let deviceID {
                DeviceSection(services: services, deviceID: deviceID)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 20, trailing: 16))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 连接：服务状态与已连接的客户端，以及复制接入命令。
private struct ConnectionSection: View {
    let server: ControlServer
    let pasteboard: MacPasteboard

    private let mcpPath = AppServices.mcpExecutablePath

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.headerToCard) {
            SectionHeader("连接")
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusDot(size: 8, color: statusColor)
                    Text(statusText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                }
                Text(clientsText)
                    .tandemText(.monoMeta)
                    .foregroundStyle(Theme.textSecondary)
                if let mcpPath {
                    Button("复制接入命令") { pasteboard.writeString(ClaudeSetup.addCommand(mcpPath: mcpPath)) }
                        .buttonStyle(TandemButtonStyle(.secondary))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tandemCard(padding: EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
        }
    }

    private var statusText: String {
        switch server.status {
        case .running: "运行中"
        case .failed(let reason): "启动失败：\(reason)"
        case .stopped: "未启动"
        }
    }

    private var statusColor: Color {
        switch server.status {
        case .running: Theme.success
        case .failed: Theme.danger
        case .stopped: Theme.textSecondary
        }
    }

    private var clientsText: String {
        let names = server.clients.map(\.name)
        guard !names.isEmpty else { return "0 个客户端" }
        return "\(names.count) 个客户端：\(names.joined(separator: "、"))"
    }
}

/// 接入：「添加到 Claude Code」，以及可复制的命令与 JSON 配置。路径始终取 App 包内的 tandem-mcp。
private struct SetupSection: View {
    let pasteboard: MacPasteboard

    @State private var installing = false
    @State private var result: (ok: Bool, output: String)?

    private let mcpPath = AppServices.mcpExecutablePath

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.headerToCard) {
            SectionHeader("接入")
            HStack(spacing: 8) {
                Button("添加到 Claude Code", action: install)
                    .buttonStyle(TandemButtonStyle(.primary))
                    .disabled(mcpPath == nil || installing)
                if installing { ProgressView().controlSize(.small) }
            }
            if let mcpPath {
                if let result { resultView(result) }
                snippet("命令", ClaudeSetup.addCommand(mcpPath: mcpPath), dark: true)
                snippet("JSON 配置（其他 MCP 客户端）", ClaudeSetup.jsonConfig(mcpPath: mcpPath), dark: false)
            } else {
                Text("未找到 tandem-mcp，请重新构建")
                    .tandemText(.body)
                    .foregroundStyle(Theme.danger)
            }
        }
    }

    private func install() {
        guard let mcpPath else { return }
        installing = true
        result = nil
        Task {
            result = await ClaudeSetup.install(mcpPath: mcpPath)
            installing = false
        }
    }

    @ViewBuilder private func resultView(_ result: (ok: Bool, output: String)) -> some View {
        Text(result.ok ? "已添加到 Claude Code" : "添加失败")
            .tandemText(.body)
            .foregroundStyle(result.ok ? Theme.success : Theme.danger)
        if !result.output.isEmpty {
            Text(result.output)
                .tandemText(.monoMeta)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                .background(Theme.controlHover, in: RoundedRectangle(cornerRadius: Metrics.buttonRadius))
        }
    }

    /// 命令片段用深色代码块，JSON 片段用浅灰底。
    private func snippet(_ title: String, _ text: String, dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).tandemText(.meta).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("拷贝") { pasteboard.writeString(text) }
                    .buttonStyle(TandemButtonStyle(.link))
            }
            Text(text)
                .tandemText(.mono)
                .foregroundStyle(dark ? Theme.codeDarkText : Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                .background(dark ? Theme.codeDark : Theme.controlHover, in: RoundedRectangle(cornerRadius: Metrics.buttonRadius))
        }
    }
}

/// 当前设备：「禁止 AI 操作」开关；会话因 AI 而运行时给出提示。
private struct DeviceSection: View {
    let services: AppServices
    let deviceID: String

    var body: some View {
        let locked = services.locks.isLocked(deviceID)
        VStack(alignment: .leading, spacing: Metrics.headerToCard) {
            SectionHeader("当前设备")
            VStack(spacing: 0) {
                CardRow("禁止 AI 操作", subtitle: AITab.lockSubtitle(locked: locked)) {
                    Toggle("禁止 AI 操作", isOn: Binding(
                        get: { services.locks.isLocked(deviceID) },
                        set: setLocked))
                        .labelsHidden()
                        .toggleStyle(TandemSwitchStyle())
                }
            }
            .tandemCard()
            if let hint = AppPolicy.aiIdleHint(mirrors: services.model.mirrors, id: deviceID) {
                Text(hint)
                    .tandemText(.meta)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    /// 切换锁定（打开时同时停止 AI 使用）并写一条来源为「你」的记录。
    private func setLocked(_ on: Bool) {
        let services = services
        let deviceID = deviceID
        Task { await services.setAILocked(deviceID, on) }
    }
}
