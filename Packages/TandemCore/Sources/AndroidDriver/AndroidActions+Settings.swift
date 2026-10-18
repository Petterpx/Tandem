import Foundation
import DeviceCore

extension AndroidActions {
    public func devOptions() async throws -> DevOptions {
        AndroidCommands.DevSettings.parse(try await shellChecked(AndroidCommands.DevSettings.readCommand).stdout)
    }

    public func setDevOption(_ option: DevOption) async throws {
        _ = try await shellChecked(try AndroidCommands.DevSettings.setCommand(option))
    }

    public func systemSettings(appPackage: String?) async throws -> SystemSettings {
        let pkg = try appPackage.map(PackageName.validate)
        let supported = try await sdkLevel() >= 33
        let night = try await shellChecked(AndroidCommands.System.nightCommand).stdout
        // font_scale 为 null 或空表示系统默认 1.0。
        let font = AndroidCommands.System.parseFontScale(try await shellChecked(AndroidCommands.System.fontScaleCommand).stdout)
        var locale: String?
        if supported, let pkg {
            let l = try await shellChecked("cmd locale get-app-locales \(pkg)").stdout
            locale = AndroidCommands.System.parseAppLocales(l)
        }
        return SystemSettings(
            darkMode: AndroidCommands.System.parseNight(night),
            fontScale: font ?? 1.0,
            appLocale: locale,
            appLocaleSupported: supported
        )
    }

    public func setSystem(_ setting: SystemSetting) async throws {
        // 先校验参数与系统版本，再执行命令。
        let command = try AndroidCommands.System.setCommand(setting)
        if case .appLocale = setting, try await sdkLevel() < 33 {
            throw DeviceError.unsupported("该系统版本不支持设置 App 语言（需要 Android 13+）")
        }
        _ = try await shellChecked(command)
    }

    public func openSystemLocaleSettings() async throws {
        let out = try await shellChecked("am start -a android.settings.LOCALE_SETTINGS").output
        if AndroidCommands.Apps.hasErrorLine(out) {
            throw DeviceError(code: .CONNECTION_FAILED, message: "打开语言设置失败：\(out.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
    }
}
