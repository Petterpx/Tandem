import DeviceCore
import SwiftUI

/// 开发者分段（spec §3.6）：「显示触摸点」「布局边界」「保持唤醒」三个开关和「动画倍速」下拉；修改后重新读取该分段。
struct DevOptionsSection: View {
    let model: QuickActionsModel
    let deviceID: String

    /// 最近一次修改的行，修改进行中在该行显示进度。
    @State private var changing: String?

    private var busy: Bool { model.isBusy(deviceID, .devOptions) }
    private var options: DevOptions? { try? model.devOptions[deviceID]?.get() }

    /// 读不到时的原因：整段读取失败、尚未读取，或单项读不到。
    private var unknownReason: String {
        switch model.devOptions[deviceID] {
        case .failure(let error)?: QuickActionsModel.reason(error)
        case nil: "尚未读取"
        case .success?: "读不到当前值"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            toggle("显示触摸点", options?.showTouches) { .showTouches($0) }
            toggle("布局边界", options?.layoutBounds) { .layoutBounds($0) }
            toggle("保持唤醒", options?.stayAwake) { .stayAwake($0) }
            SettingChoiceRow(
                title: "动画倍速", options: DevOption.animationScales,
                value: options?.animationScale.map { SettingChoiceRow<Double>.snap($0, to: DevOption.animationScales) },
                label: Self.scaleLabel, unknownReason: unknownReason,
                disabled: busy, spinning: busy && changing == "动画倍速"
            ) { set("动画倍速", .animationScale($0)) }
        }
        .font(.callout)
        .onChange(of: deviceID) { changing = nil }
    }

    private func toggle(_ title: String, _ value: Bool?, _ option: @escaping (Bool) -> DevOption) -> some View {
        SettingToggleRow(
            title: title, value: value, unknownReason: unknownReason,
            disabled: busy, spinning: busy && changing == title
        ) { set(title, option($0)) }
    }

    private func set(_ row: String, _ o: DevOption) {
        changing = row
        let id = deviceID
        Task { await model.setDevOption(id, o) }
    }

    /// 0 → 「关」，其余 → 「0.5x」「2x」。
    static func scaleLabel(_ v: Double) -> String {
        v == 0 ? "关" : "\(SettingChoiceRow<Double>.format(v))x"
    }
}

// MARK: - 设置行

/// 开关行：值读不到时显示「—」，悬停显示原因。
struct SettingToggleRow: View {
    let title: String
    let value: Bool?
    let unknownReason: String
    let disabled: Bool
    let spinning: Bool
    let onSet: (Bool) -> Void

    var body: some View {
        HStack {
            Text(title).foregroundStyle(Theme.textPrimary)
            Spacer()
            if spinning { ProgressView().controlSize(.small) }
            if let value {
                Toggle(title, isOn: Binding(get: { value }, set: { onSet($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(disabled)
            } else {
                UnreadableMark(reason: unknownReason)
            }
        }
    }
}

/// 下拉行：选项为固定值；当前值不在选项里时额外列出，下拉不会显示空白。
struct SettingChoiceRow<Value: Hashable>: View {
    let title: String
    let options: [Value]
    let value: Value?
    let label: (Value) -> String
    let unknownReason: String
    let disabled: Bool
    let spinning: Bool
    let onSet: (Value) -> Void

    var body: some View {
        HStack {
            Text(title).foregroundStyle(Theme.textPrimary)
            Spacer()
            if spinning { ProgressView().controlSize(.small) }
            if let value {
                Picker(title, selection: Binding(get: { value }, set: { if $0 != value { onSet($0) } })) {
                    ForEach(options, id: \.self) { Text(label($0)).tag($0) }
                    if !options.contains(value) { Text(label(value)).tag(value) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .disabled(disabled)
            } else {
                UnreadableMark(reason: unknownReason)
            }
        }
    }
}

extension SettingChoiceRow where Value == Double {
    /// 设备读回的小数与选项只差浮点误差时归到该选项，下拉才能选中它。
    static func snap(_ v: Double, to options: [Double]) -> Double {
        options.first { abs($0 - v) < 0.001 } ?? v
    }

    /// 去掉多余的小数位：1.0 → "1"，0.85 → "0.85"。
    static func format(_ v: Double) -> String {
        String(format: "%g", v)
    }
}
