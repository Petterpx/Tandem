import Foundation
import DeviceCore

extension AndroidActions {
    public func foregroundApp() async throws -> AppInfo {
        let out = try await shellChecked(AndroidCommands.Apps.foregroundCommand).stdout
        guard let fg = AndroidCommands.Apps.parseForeground(out) else {
            throw DeviceError(code: .CONNECTION_FAILED, message: "无法识别前台 App", suggestion: "请解锁设备并打开目标 App")
        }
        // 版本名读取失败不影响前台信息。
        let version = try? await shellChecked("dumpsys package \(fg.package) | grep -m1 versionName").stdout
        return AppInfo(package: fg.package, activity: fg.activity, versionName: version.flatMap(AndroidCommands.Apps.parseVersionName))
    }

    public func launchApp(_ package: String) async throws {
        let pkg = try PackageName.validate(package)
        let resolved = try await shellChecked("cmd package resolve-activity --brief -c android.intent.category.LAUNCHER \(pkg)").stdout
        guard let component = AndroidCommands.Apps.parseLaunchComponent(resolved) else {
            throw DeviceError(code: .CONNECTION_FAILED, message: "该应用没有可启动的界面")
        }
        let out = try await shellChecked("am start -n \(component)").output
        if out.contains("Error") {
            throw DeviceError(code: .CONNECTION_FAILED, message: "启动失败：\(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    public func forceStop(_ package: String) async throws {
        let pkg = try PackageName.validate(package)
        _ = try await shellChecked("am force-stop \(pkg)")
    }

    public func clearData(_ package: String) async throws {
        try await runExpectingSuccess("pm clear \(try PackageName.validate(package))")
    }

    public func uninstall(_ package: String) async throws {
        try await runExpectingSuccess("pm uninstall \(try PackageName.validate(package))")
    }

    public func openURL(_ url: String) async throws {
        let out = try await shellChecked("am start -a android.intent.action.VIEW -d \(ShellQuote.quote(url))").output
        if out.contains("unable to resolve Intent") {
            throw DeviceError(code: .CONNECTION_FAILED, message: "没有应用能打开该链接")
        }
        if out.contains("Error") {
            throw DeviceError(code: .CONNECTION_FAILED, message: "打开链接失败：\(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }

    /// pm 类命令：输出不含 `Success` 即失败。
    private func runExpectingSuccess(_ command: String) async throws {
        let out = try await shellChecked(command).output
        guard out.contains("Success") else {
            throw DeviceError(code: .CONNECTION_FAILED, message: "操作失败：\(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
