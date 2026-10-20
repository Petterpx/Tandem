import SwiftUI

/// 自绘开关：只画轨道与滑块，辅助功能沿用系统 Toggle。
struct TandemSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    static func trackColor(isOn: Bool, isEnabled: Bool) -> Color {
        if !isEnabled { return Theme.toggleDisabled }
        return isOn ? Theme.accent : Theme.toggleOff
    }

    func makeBody(configuration: Configuration) -> some View {
        let size = Metrics.switchSize
        Capsule()
            .fill(Self.trackColor(isOn: configuration.isOn, isEnabled: isEnabled))
            .frame(width: size.width, height: size.height)
            .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                Circle()
                    .fill(Theme.knob)
                    .frame(width: Metrics.knobSize, height: Metrics.knobSize)
                    .shadow(color: Theme.shadow.opacity(0.2), radius: 1, y: 1)
                    .padding(2)
            }
            .animation(.easeOut(duration: 0.12), value: configuration.isOn)
            .contentShape(Capsule())
            .onTapGesture { if isEnabled { configuration.isOn.toggle() } }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
    }
}
