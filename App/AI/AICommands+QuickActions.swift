import DeviceCore
import Foundation

/// 快捷操作的 AI 入口：都不需要投屏会话。感知类经 run（成功不写记录，锁定时照常可用），
/// 操作类经 act(needsSession: false)（受「禁止 AI 操作」限制，同一设备排队执行）。返回给 AI 的文本用英文键，便于解析。
extension AICommands {
    /// shell 超时。
    static let shellTimeout: Duration = .seconds(30)
    /// 返回给 AI 的 shell 输出上限（UTF-8 字节，含截断说明）。
    static let shellOutputLimit = 64 * 1024
    /// shell 超时时随错误附带的部分输出上限（UTF-8 字节）。
    static let shellPartialLimit = 2 * 1024

    // MARK: 应用

    func currentApp(_ device: DeviceInfo) async throws -> String {
        presence.touch(device.id)
        return try await run("current_app", device) {
            let app = try await deviceActions(device).foregroundApp()
            return "\(app.package)\nActivity: \(app.activity ?? "未知")\n版本: \(app.versionName ?? "未知")"
        }
    }

    func launchApp(_ device: DeviceInfo, package: String) async throws -> String {
        try await act("launch_app \(package)", device, needsSession: false) {
            try await deviceActions(device).launchApp(package)
            return "已启动 \(package)"
        }
    }

    func forceStop(_ device: DeviceInfo, package: String) async throws -> String {
        try await act("force_stop \(package)", device, needsSession: false) {
            try await deviceActions(device).forceStop(package)
            return "已强行停止 \(package)"
        }
    }

    func clearAppData(_ device: DeviceInfo, package: String) async throws -> String {
        try await act("clear_app_data \(package)", device, needsSession: false) {
            try await deviceActions(device).clearData(package)
            return "已清除 \(package) 的数据"
        }
    }

    func uninstallApp(_ device: DeviceInfo, package: String) async throws -> String {
        try await act("uninstall_app \(package)", device, needsSession: false) {
            try await deviceActions(device).uninstall(package)
            return "已卸载 \(package)"
        }
    }

    func openURL(_ device: DeviceInfo, url: String) async throws -> String {
        try await act("open_url \(url)", device, needsSession: false) {
            try await deviceActions(device).openURL(url)
            return "已打开 \(url)"
        }
    }

    // MARK: 网络

    func networkState(_ device: DeviceInfo) async throws -> String {
        presence.touch(device.id)
        return try await run("get_network_state", device) {
            Self.format(try await deviceActions(device).networkState())
        }
    }

    /// 返回回读后的实际状态。经 Wi-Fi 调试的设备不允许 AI 关闭 Wi-Fi（面板上人可以确认后执行）。
    func setNetwork(_ device: DeviceInfo, kind: NetworkKind, on: Bool) async throws -> String {
        try await act("set_network \(kind.rawValue) \(Self.onOff(on))", device, needsSession: false) {
            // 在 act 内拒绝：照常记为失败，且不调用 adb
            if DeviceCommands.needsWifiConfirmation(device, kind: kind, on: on) {
                throw DeviceError.unsupported("设备经 Wi-Fi 调试连接，关闭 Wi-Fi 会断开连接")
            }
            return Self.format(try await deviceActions(device).setNetwork(kind, on: on))
        }
    }

    // MARK: 开发者选项

    func devOptions(_ device: DeviceInfo) async throws -> String {
        presence.touch(device.id)
        return try await run("get_dev_options", device) {
            Self.format(try await deviceActions(device).devOptions())
        }
    }

    /// 返回确认行，回读成功时附上当前各项。
    func setDevOption(_ device: DeviceInfo, _ option: DevOption) async throws -> String {
        let value = switch option {
        case .showTouches(let on): "show_touches \(Self.onOff(on))"
        case .layoutBounds(let on): "layout_bounds \(Self.onOff(on))"
        case .stayAwake(let on): "stay_awake \(Self.onOff(on))"
        case .animationScale(let v): "animation_scale \(v.compactText)"
        }
        return try await act("set_dev_option \(value)", device, needsSession: false) {
            let actions = try await deviceActions(device)
            try await actions.setDevOption(option)
            // 回读只是附带信息：读取失败不影响已完成的设置
            let state = try? await actions.devOptions()
            return Self.confirmation(value, state.map(Self.format))
        }
    }

    // MARK: 系统设置

    /// package 非空时附该 App 的语言。
    func systemSettings(_ device: DeviceInfo, package: String?) async throws -> String {
        presence.touch(device.id)
        return try await run("get_system_settings", device) {
            let settings = try await deviceActions(device).systemSettings(appPackage: package)
            return Self.format(settings, withLocale: package != nil)
        }
    }

    /// 返回确认行，回读成功时附上当前各项（设置 App 语言时含该 App 的语言）。
    func setSystem(_ device: DeviceInfo, _ setting: SystemSetting) async throws -> String {
        var package: String?
        let value: String
        switch setting {
        case .darkMode(let on): value = "dark_mode \(Self.onOff(on))"
        case .fontScale(let v): value = "font_scale \(v.compactText)"
        case .appLocale(let p, let tag):
            package = p
            value = "app_locale \(p) \(tag.isEmpty ? "跟随系统" : tag)"
        }
        return try await act("set_system \(value)", device, needsSession: false) {
            let actions = try await deviceActions(device)
            try await actions.setSystem(setting)
            let state = try? await actions.systemSettings(appPackage: package)
            return Self.confirmation(value, state.map { Self.format($0, withLocale: package != nil) })
        }
    }

    // MARK: shell

    /// 返回 `exit: n` 加 stdout，stderr 非空时追加一段；退出码非 0 不算失败（AI 要的是原始输出）。
    /// 超时抛 TIMEOUT 并附部分输出；超过 64 KB 截断并注明原长度。
    func shell(_ device: DeviceInfo, command: String) async throws -> String {
        try await act("shell \(command.prefix(80))", device, needsSession: false) {
            let r = try await deviceActions(device).shell(command, timeout: Self.shellTimeout)
            if r.timedOut {
                let output = [r.stdout, r.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
                throw DeviceError(
                    code: .TIMEOUT, message: "shell 命令超时",
                    suggestion: output.isEmpty
                        ? "没有取得输出" : "部分输出：\n" + Self.prefix(output, bytes: Self.shellPartialLimit))
            }
            var text = "exit: \(r.exitCode)\n" + r.stdout
            if !r.stderr.isEmpty {
                if !text.hasSuffix("\n") { text += "\n" }
                text += "--- stderr ---\n" + r.stderr
            }
            return Self.truncated(text, limit: Self.shellOutputLimit)
        }
    }

    // MARK: 文本格式

    private static func format(_ s: NetworkState) -> String {
        NetworkKind.allCases.map { "\($0.rawValue): \(tri(s[$0]))" }.joined(separator: "\n")
    }

    private static func format(_ o: DevOptions) -> String {
        [
            "show_touches: \(tri(o.showTouches))",
            "layout_bounds: \(tri(o.layoutBounds))",
            "stay_awake: \(tri(o.stayAwake))",
            "animation_scale: \(o.animationScale.map(\.compactText) ?? "unknown")",
        ].joined(separator: "\n")
    }

    private static func format(_ s: SystemSettings, withLocale: Bool) -> String {
        var lines = ["dark_mode: \(tri(s.darkMode))", "font_scale: \(s.fontScale.map(\.compactText) ?? "unknown")"]
        if withLocale {
            let locale = if !s.appLocaleSupported {
                "不支持（需要 Android 13+）"
            } else if let tag = s.appLocale {
                tag.isEmpty ? "跟随系统" : tag
            } else {
                "unknown"
            }
            lines.append("app_locale: \(locale)")
        }
        return lines.joined(separator: "\n")
    }

    /// 「已设置 …」，有回读结果时另起几行附上。
    private static func confirmation(_ value: String, _ state: String?) -> String {
        "已设置 \(value)" + (state.map { "\n" + $0 } ?? "")
    }

    private static func onOff(_ on: Bool) -> String { on ? "on" : "off" }
    /// nil 为 unknown。
    private static func tri(_ on: Bool?) -> String { on.map(onOff) ?? "unknown" }

    /// 超过 limit 字节时截断，截断说明也计入 limit；说明里的 N 是截断前的总字节数。
    private static func truncated(_ text: String, limit: Int) -> String {
        let total = text.utf8.count
        guard total > limit else { return text }
        let note = "\n…（输出已截断，共 \(total) 字节）"
        return prefix(text, bytes: limit - note.utf8.count) + note
    }

    /// 不超过 bytes 个 UTF-8 字节的最长前缀，在字符边界处截断。
    private static func prefix(_ s: String, bytes: Int) -> String {
        var used = 0
        var end = s.startIndex
        for i in s.indices {
            used += s[i].utf8.count
            if used > bytes { break }
            end = s.index(after: i)
        }
        return String(s[..<end])
    }
}
