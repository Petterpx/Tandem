import DeviceCore
import SwiftUI

/// 「AI」标签（spec §5.4）：连接状态、接入 Claude Code、当前设备的「禁止 AI 操作」。
/// 前两节是全局的，未选设备时也显示。
struct AITab: View {
    let services: AppServices
    let deviceID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ConnectionSection(server: services.server)
                SetupSection(pasteboard: services.pasteboard)
                if let deviceID {
                    DeviceSection(services: services, deviceID: deviceID)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private func sectionTitle(_ title: String) -> some View {
    Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(Theme.textSecondary)
}

/// 连接：服务状态与已连接的客户端。
private struct ConnectionSection: View {
    let server: ControlServer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("连接")
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 8, height: 8)
                Text(statusText).foregroundStyle(Theme.textPrimary).textSelection(.enabled)
            }
            Text(clientsText).foregroundStyle(Theme.textSecondary)
        }
        .font(.callout)
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
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("接入")
            HStack(spacing: 8) {
                Button("添加到 Claude Code", action: install)
                    .disabled(mcpPath == nil || installing)
                if installing { ProgressView().controlSize(.small) }
            }
            if let mcpPath {
                if let result { resultView(result) }
                snippet("命令", ClaudeSetup.addCommand(mcpPath: mcpPath))
                snippet("JSON 配置（其他 MCP 客户端）", ClaudeSetup.jsonConfig(mcpPath: mcpPath))
            } else {
                Text("未找到 tandem-mcp，请重新构建")
                    .font(.callout)
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
            .font(.callout)
            .foregroundStyle(result.ok ? Theme.success : Theme.danger)
        if !result.output.isEmpty {
            Text(result.output)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func snippet(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("拷贝") { pasteboard.writeString(text) }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(Theme.canvas, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// 当前设备：「禁止 AI 操作」开关；会话因 AI 而运行时给出提示。
private struct DeviceSection: View {
    let services: AppServices
    let deviceID: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("当前设备")
            Toggle("禁止 AI 操作", isOn: Binding(
                get: { services.locks.isLocked(deviceID) },
                set: setLocked))
                .foregroundStyle(Theme.textPrimary)
            if services.model.mirrors.ai.contains(deviceID) {
                Text("AI 正在使用，空闲 5 分钟后停止")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .font(.callout)
    }

    /// 切换锁定并写一条来源为「你」的记录。
    private func setLocked(_ on: Bool) {
        services.locks.setLocked(deviceID, on)
        let model = services.model
        guard let device = model.devices.first(where: { $0.id == deviceID }) ?? model.lastKnownDevices[deviceID] else { return }
        services.runner.note(on ? "禁止 AI 操作" : "允许 AI 操作", device: device, source: .user)
    }
}
