import Foundation

/// 不依赖投屏会话的设备操作。
public protocol DeviceActions: Sendable {
    /// 截图，返回设备原分辨率的 PNG 数据。
    func screenshot() async throws -> Data
    /// 读取当前界面结构。
    func uiTree() async throws -> UITree

    /// 读取网络开关状态。
    func networkState() async throws -> NetworkState
    /// 切换网络开关，返回回读后的状态。
    func setNetwork(_ kind: NetworkKind, on: Bool) async throws -> NetworkState
    /// 当前前台应用。
    func foregroundApp() async throws -> AppInfo
    func launchApp(_ package: String) async throws
    func forceStop(_ package: String) async throws
    func clearData(_ package: String) async throws
    func uninstall(_ package: String) async throws
    func openURL(_ url: String) async throws
    func devOptions() async throws -> DevOptions
    func setDevOption(_ option: DevOption) async throws
    func systemSettings(appPackage: String?) async throws -> SystemSettings
    func setSystem(_ setting: SystemSetting) async throws
    func openSystemLocaleSettings() async throws
    func shell(_ command: String, timeout: Duration) async throws -> ShellResult
}

/// 新增操作的默认实现：设备不支持。
extension DeviceActions {
    public func networkState() async throws -> NetworkState { throw Self.unsupportedAction }
    public func setNetwork(_ kind: NetworkKind, on: Bool) async throws -> NetworkState { throw Self.unsupportedAction }
    public func foregroundApp() async throws -> AppInfo { throw Self.unsupportedAction }
    public func launchApp(_ package: String) async throws { throw Self.unsupportedAction }
    public func forceStop(_ package: String) async throws { throw Self.unsupportedAction }
    public func clearData(_ package: String) async throws { throw Self.unsupportedAction }
    public func uninstall(_ package: String) async throws { throw Self.unsupportedAction }
    public func openURL(_ url: String) async throws { throw Self.unsupportedAction }
    public func devOptions() async throws -> DevOptions { throw Self.unsupportedAction }
    public func setDevOption(_ option: DevOption) async throws { throw Self.unsupportedAction }
    public func systemSettings(appPackage: String?) async throws -> SystemSettings { throw Self.unsupportedAction }
    public func setSystem(_ setting: SystemSetting) async throws { throw Self.unsupportedAction }
    public func openSystemLocaleSettings() async throws { throw Self.unsupportedAction }
    public func shell(_ command: String, timeout: Duration) async throws -> ShellResult { throw Self.unsupportedAction }

    private static var unsupportedAction: DeviceError { .unsupported("该设备不支持此操作") }
}
