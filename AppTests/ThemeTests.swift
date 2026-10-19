import Testing
import SwiftUI
@testable import Tandem

@Suite struct ThemeTests {
    typealias Row = (name: String, color: Color, light: (UInt32, CGFloat), dark: (UInt32, CGFloat))

    /// spec §3.1 的色表：浅色 / 深色（hex, alpha）。
    static let table: [Row] = [
        ("windowBackground", Theme.windowBackground, (0xFFFFFF, 1), (0x1E1F22, 1)),
        ("titleBar", Theme.titleBar, (0xF6F6F8, 1), (0x2A2B2F, 1)),
        ("card", Theme.card, (0xFFFFFF, 1), (0x2C2E33, 1)),
        ("sidebar", Theme.sidebar, (0xF4F4F6, 1), (0x1F2125, 1)),
        ("panel", Theme.panel, (0xFBFBFC, 1), (0x26282C, 1)),
        ("canvas", Theme.canvas, (0xEEF0F3, 1), (0x18191C, 1)),
        ("canvasDot", Theme.canvasDot, (0x000000, 0.05), (0xFFFFFF, 0.06)),
        ("border", Theme.border, (0xE5E5EA, 1), (0x35383D, 1)),
        ("cardBorder", Theme.cardBorder, (0xE8E8ED, 1), (0x3A3B40, 1)),
        ("controlBorder", Theme.controlBorder, (0xD8D8DD, 1), (0x48494F, 1)),
        ("rowDivider", Theme.rowDivider, (0xF0F0F3, 1), (0x2E2F33, 1)),
        ("hover", Theme.hover, (0x000000, 0.04), (0xFFFFFF, 0.06)),
        ("controlHover", Theme.controlHover, (0xF2F2F5, 1), (0x34353A, 1)),
        ("textPrimary", Theme.textPrimary, (0x1D1D1F, 1), (0xECEDEF, 1)),
        ("textSecondary", Theme.textSecondary, (0x6E6E73, 1), (0x9BA1AB, 1)),
        ("textTertiary", Theme.textTertiary, (0x3A3A3C, 1), (0xC7C7CC, 1)),
        ("accent", Theme.accent, (0x2F6FED, 1), (0x5A8DF2, 1)),
        ("accentStrong", Theme.accentStrong, (0x2459C9, 1), (0x7FA6F5, 1)),
        ("accentTint", Theme.accentTint, (0xEEF2FF, 1), (0x1E2A44, 1)),
        ("accentTintBorder", Theme.accentTintBorder, (0xD9E3FB, 1), (0x2C3D63, 1)),
        ("aiTint", Theme.aiTint, (0xF3EEFF, 1), (0x2D2545, 1)),
        ("aiText", Theme.aiText, (0x6B4FD8, 1), (0xA894F0, 1)),
        ("chipNeutral", Theme.chipNeutral, (0xEDEDF0, 1), (0x34353A, 1)),
        ("chipCount", Theme.chipCount, (0xE5E5EA, 1), (0x3A3B40, 1)),
        ("success", Theme.success, (0x1F9D55, 1), (0x3DC47E, 1)),
        ("successTint", Theme.successTint, (0xE8F5EE, 1), (0x17301F, 1)),
        ("successText", Theme.successText, (0x146C3B, 1), (0x6FD69C, 1)),
        ("danger", Theme.danger, (0xD93025, 1), (0xF26B60, 1)),
        ("dotOff", Theme.dotOff, (0xAEAEB2, 1), (0x636366, 1)),
        ("toggleOff", Theme.toggleOff, (0xD1D1D6, 1), (0x4A4B50, 1)),
        ("toggleDisabled", Theme.toggleDisabled, (0xE5E5EA, 1), (0x34353A, 1)),
        ("warnTint", Theme.warnTint, (0xFFF6E0, 1), (0x3A2F12, 1)),
        ("warnBorder", Theme.warnBorder, (0xF1E0B0, 1), (0x5C4A1C, 1)),
        ("warnText", Theme.warnText, (0x7A5200, 1), (0xF5C76B, 1)),
        ("bezel", Theme.bezel, (0x1C1C1E, 1), (0x0A0A0B, 1)),
        ("dashed", Theme.dashed, (0xC7C7CC, 1), (0x55565B, 1)),
        ("knob", Theme.knob, (0xFFFFFF, 1), (0xF2F2F5, 1)),
        ("codeDark", Theme.codeDark, (0x1D1D1F, 1), (0x111113, 1)),
        ("codeDarkText", Theme.codeDarkText, (0xF2F2F5, 1), (0xF2F2F5, 1)),
        ("shadow", Theme.shadow, (0x000000, 1), (0x000000, 1)),
        ("shadowDeep", Theme.shadowDeep, (0x101828, 1), (0x101828, 1)),
    ]

    @Test func lightValuesMatchSpec() {
        for row in Self.table {
            let got = ColorProbe.rgba(row.color, dark: false)
            #expect(got.hex == row.light.0, "\(row.name) light hex")
            #expect(abs(got.alpha - row.light.1) < 0.005, "\(row.name) light alpha")
        }
    }

    @Test func darkValuesMatchSpec() {
        for row in Self.table {
            let got = ColorProbe.rgba(row.color, dark: true)
            #expect(got.hex == row.dark.0, "\(row.name) dark hex")
            #expect(abs(got.alpha - row.dark.1) < 0.005, "\(row.name) dark alpha")
        }
    }

    @Test func everyTokenHasDarkVariant() {
        let same: Set<String> = ["shadow", "shadowDeep", "codeDarkText"]
        for row in Self.table where !same.contains(row.name) {
            let light = ColorProbe.rgba(row.color, dark: false)
            let dark = ColorProbe.rgba(row.color, dark: true)
            #expect(light.hex != dark.hex || abs(light.alpha - dark.alpha) >= 0.005, "\(row.name) has no dark variant")
        }
    }

    @Test func dropOverlayAlpha() {
        #expect(abs(ColorProbe.rgba(Theme.dropOverlay, dark: false).alpha - 0.12) < 0.005)
    }

    @Test func typeScale() {
        #expect(TextRole.sectionTitle.size == 11 && TextRole.sectionTitle.weight == .semibold && TextRole.sectionTitle.tracking == 0.44)
        #expect(TextRole.body.size == 13)
        #expect(TextRole.button.size == 12)
        #expect(TextRole.meta.size == 11)
        #expect(TextRole.chip.size == 10)
        #expect(TextRole.mono.size == 12 && TextRole.mono.monospaced)
        #expect(TextRole.monoMeta.size == 11 && TextRole.monoMeta.monospaced)
        #expect(TextRole.headerTitle.size == 14 && TextRole.headerTitle.weight == .bold)
    }

    @Test func layoutMetrics() {
        #expect(Metrics.sidebarWidth == 232 && Metrics.panelWidth == 372 && Metrics.bottomHeight == 168)
        #expect(Metrics.deviceHeaderHeight == 48 && Metrics.buttonHeight == 30)
    }
}
