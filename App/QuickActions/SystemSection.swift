import DeviceCore
import SwiftUI

/// 系统分段（spec §3.7）：深色模式、字体大小、作用于「应用」分段当前目标的 App 语言，以及「打开系统语言设置」。
struct SystemSection: View {
    let model: QuickActionsModel
    let deviceID: String

    /// 最近一次修改的行，修改进行中在该行显示进度。
    @State private var changing: String?

    /// 字体大小选项（值见 `SystemSetting.fontScales`）。
    private static let fontLabels: [Double: String] = [0.85: "小", 1.0: "默认", 1.15: "大", 1.3: "特大"]
    /// App 语言选项；"" 表示跟随系统。
    private static let locales: [(tag: String, label: String)] = [
        ("", "跟随系统"), ("zh-CN", "简体中文"), ("zh-TW", "繁體中文"), ("en", "English"), ("ja", "日本語"), ("ko", "한국어"),
    ]

    private var busy: Bool { model.isBusy(deviceID, .system) }
    private var settings: SystemSettings? { try? model.system[deviceID]?.get() }
    private var package: String? { model.targetPackage(deviceID) }

    private var unknownReason: String {
        switch model.system[deviceID] {
        case .failure(let error)?: QuickActionsModel.reason(error)
        case nil: "尚未读取"
        case .success?: "读不到当前值"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(spacing: 0) {
                SettingToggleRow(
                    title: "深色模式", value: settings?.darkMode, unknownReason: unknownReason,
                    disabled: busy, spinning: spinning("深色模式")
                ) { set("深色模式", .darkMode($0)) }
                CardDivider()
                SettingChoiceRow(
                    title: "字体大小", options: SystemSetting.fontScales,
                    value: settings?.fontScale.map { SettingChoiceRow<Double>.snap($0, to: SystemSetting.fontScales) },
                    label: { Self.fontLabels[$0] ?? SettingChoiceRow<Double>.format($0) },
                    unknownReason: unknownReason, disabled: busy, spinning: spinning("字体大小")
                ) { set("字体大小", .fontScale($0)) }
                CardDivider()
                appLocaleRow
            }
            .tandemCard(padding: EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            Button("打开系统语言设置") {
                let id = deviceID
                Task { await model.openSystemLocaleSettings(id) }
            }
            .buttonStyle(TandemButtonStyle(.secondary))
        }
        .onChange(of: deviceID) { changing = nil }
    }

    // MARK: App 语言

    /// 置灰的原因：系统版本不支持，或没有目标包名。
    private var appLocaleDisabledReason: String? {
        if settings?.appLocaleSupported == false { return "需要 Android 13+" }
        if package == nil {
            return model.isReadingForeground(deviceID) ? "正在读取前台 App" : "请先在「应用」分段选择目标"
        }
        return nil
    }

    /// 只显示按当前目标读到的语言；目标刚变、尚未重读时不显示（可能是另一个包的语言）。
    private var appLocale: String? {
        model.systemMatchesTarget(deviceID) ? settings?.appLocale : nil
    }

    @ViewBuilder
    private var appLocaleRow: some View {
        if let reason = appLocaleDisabledReason {
            CardRow("App 语言") {
                Text(reason).tandemText(.meta).foregroundStyle(Theme.textSecondary)
            }
            .opacity(0.6)
            .help(reason)
        } else {
            SettingChoiceRow(
                title: "App 语言", options: Self.locales.map(\.tag), value: appLocale,
                label: { tag in Self.locales.first { $0.tag == tag }?.label ?? tag },
                unknownReason: model.systemMatchesTarget(deviceID) ? unknownReason : "尚未按当前目标读取，可点「刷新」",
                disabled: busy, spinning: spinning("App 语言")
            ) { tag in
                if let package { set("App 语言", .appLocale(package: package, tag: tag)) }
            }
            .help(ifPresent: package.map { "作用于 \($0)" })
        }
    }

    // MARK: 修改

    private func spinning(_ row: String) -> Bool { busy && changing == row }

    private func set(_ row: String, _ s: SystemSetting) {
        changing = row
        let id = deviceID
        Task { await model.setSystem(id, s) }
    }
}
