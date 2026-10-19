import Testing
import SwiftUI
@testable import Tandem

@MainActor
@Suite struct StyleTests {
    @Test func flowLayoutRows() {
        #expect(FlowLayout.rows(widths: [50, 50, 50], maxWidth: 120, spacing: 6) == [[0, 1], [2]])
        #expect(FlowLayout.rows(widths: [200, 30], maxWidth: 120, spacing: 6) == [[0], [1]])
        #expect(FlowLayout.rows(widths: [], maxWidth: 120, spacing: 6) == [])
        #expect(FlowLayout.rows(widths: [40, 40], maxWidth: .infinity, spacing: 6) == [[0, 1]])
    }

    @Test func bezelGeometry() {
        #expect(BezelGeometry.outerRadius(width: 260) == 40)
        #expect(BezelGeometry.innerRadius(screenWidth: 246) == 33)
        #expect(BezelGeometry.innerRadius(screenWidth: 0) == 0)
    }

    @Test func buttonColors() {
        #expect(TandemButtonStyle.colors(.primary, hovered: false, pressed: false).fill == Theme.accent)
        #expect(TandemButtonStyle.colors(.primary, hovered: true, pressed: false).fill == Theme.accentStrong)
        let secondary = TandemButtonStyle.colors(.secondary, hovered: false, pressed: false)
        #expect(secondary.fill == Theme.card)
        #expect(secondary.stroke == Theme.controlBorder)
        #expect(secondary.text == Theme.textPrimary)
        #expect(TandemButtonStyle.colors(.secondary, hovered: true, pressed: false).fill == Theme.controlHover)
        #expect(TandemButtonStyle.colors(.link, hovered: false, pressed: false).text == Theme.accentStrong)
    }

    @Test func switchTrackColors() {
        #expect(TandemSwitchStyle.trackColor(isOn: true, isEnabled: true) == Theme.accent)
        #expect(TandemSwitchStyle.trackColor(isOn: false, isEnabled: true) == Theme.toggleOff)
        #expect(TandemSwitchStyle.trackColor(isOn: true, isEnabled: false) == Theme.toggleDisabled)
    }
}
