import DeviceCore
import Foundation

/// 记录每次调用的设备操作替身：调用记为「方法名 参数」，各方法的返回值或错误可配置。
final class RecordingActions: DeviceActions, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []

    var calls: [String] { lock.withLock { _calls } }

    /// 方法名（如 "forceStop"、"shell"）→ 要抛出的错误。
    var errors: [String: any Error] = [:]
    var networkStateResult = NetworkState(wifi: true, data: true, airplane: false)
    var setNetworkResult: NetworkState?
    var foregroundAppResult = AppInfo(package: "com.demo")
    var devOptionsResult = DevOptions()
    var systemSettingsResult = SystemSettings(appLocaleSupported: true)
    var shellResult = ShellResult(stdout: "", stderr: "", exitCode: 0)
    /// 读取网络状态前执行的挂起点（可让某台设备的读取保持挂起，测过期结果）。
    var networkStateHook: (@Sendable () async -> Void)?
    /// 读取前台 App 前执行的挂起点（测读取进行中的界面状态）。
    var foregroundAppHook: (@Sendable () async -> Void)?

    private func record(_ call: String, method: String) throws {
        lock.withLock { _calls.append(call) }
        if let error = errors[method] { throw error }
    }

    func screenshot() async throws -> Data { try record("screenshot", method: "screenshot"); return Data() }
    func uiTree() async throws -> UITree {
        try record("uiTree", method: "uiTree")
        return UITree(screen: CGSize(width: 1080, height: 2400), elements: [])
    }
    func networkState() async throws -> NetworkState {
        try record("networkState", method: "networkState")
        if let networkStateHook { await networkStateHook() }
        return networkStateResult
    }
    func setNetwork(_ kind: NetworkKind, on: Bool) async throws -> NetworkState {
        try record("setNetwork \(kind.rawValue) \(on)", method: "setNetwork")
        if let setNetworkResult { return setNetworkResult }
        var s = networkStateResult
        switch kind {
        case .wifi: s.wifi = on
        case .data: s.data = on
        case .airplane: s.airplane = on
        }
        return s
    }
    func foregroundApp() async throws -> AppInfo {
        try record("foregroundApp", method: "foregroundApp")
        if let foregroundAppHook { await foregroundAppHook() }
        return foregroundAppResult
    }
    func launchApp(_ package: String) async throws { try record("launchApp \(package)", method: "launchApp") }
    func forceStop(_ package: String) async throws { try record("forceStop \(package)", method: "forceStop") }
    func clearData(_ package: String) async throws { try record("clearData \(package)", method: "clearData") }
    func uninstall(_ package: String) async throws { try record("uninstall \(package)", method: "uninstall") }
    func openURL(_ url: String) async throws { try record("openURL \(url)", method: "openURL") }
    func devOptions() async throws -> DevOptions { try record("devOptions", method: "devOptions"); return devOptionsResult }
    func setDevOption(_ option: DevOption) async throws { try record("setDevOption \(option)", method: "setDevOption") }
    func systemSettings(appPackage: String?) async throws -> SystemSettings {
        try record("systemSettings \(appPackage ?? "-")", method: "systemSettings")
        return systemSettingsResult
    }
    func setSystem(_ setting: SystemSetting) async throws { try record("setSystem \(setting)", method: "setSystem") }
    func openSystemLocaleSettings() async throws { try record("openSystemLocaleSettings", method: "openSystemLocaleSettings") }
    func shell(_ command: String, timeout: Duration) async throws -> ShellResult {
        try record("shell \(command)", method: "shell")
        return shellResult
    }
}
