import AppKit
import SwiftUI

/// 全部界面颜色（spec §8）：浅色为主，侧栏冷灰、面板近白、投屏画布浅灰加淡点阵，单一强调色 #2F6FED。
/// 每个颜色给出浅色值，深色值由它派生：中性色按明度翻转后压暗，强调 / 状态色略微提亮，随系统外观切换。
enum Theme {
    // 窗口与表面
    static let windowBackground = dynamic("windowBackground", light: 0xFFFFFF, dark: 0x1E1F22)
    static let titleBar = dynamic("titleBar", light: 0xF6F6F8, dark: 0x2A2B2F)
    static let card = dynamic("card", light: 0xFFFFFF, dark: 0x2C2E33)
    static let sidebar = dynamic("sidebar", light: 0xF4F4F6, dark: 0x1F2125)
    static let panel = dynamic("panel", light: 0xFBFBFC, dark: 0x26282C)
    static let canvas = dynamic("canvas", light: 0xEEF0F3, dark: 0x18191C)
    static let canvasDot = dynamic("canvasDot", light: 0x000000, dark: 0xFFFFFF, alpha: 0.05, darkAlpha: 0.06)

    // 描边与分隔
    static let border = dynamic("border", light: 0xE5E5EA, dark: 0x35383D)
    static let cardBorder = dynamic("cardBorder", light: 0xE8E8ED, dark: 0x3A3B40)
    static let controlBorder = dynamic("controlBorder", light: 0xD8D8DD, dark: 0x48494F)
    static let rowDivider = dynamic("rowDivider", light: 0xF0F0F3, dark: 0x2E2F33)
    static let dashed = dynamic("dashed", light: 0xC7C7CC, dark: 0x55565B)

    // 悬停
    static let hover = dynamic("hover", light: 0x000000, dark: 0xFFFFFF, alpha: 0.04, darkAlpha: 0.06)
    static let controlHover = dynamic("controlHover", light: 0xF2F2F5, dark: 0x34353A)

    // 文字
    static let textPrimary = dynamic("textPrimary", light: 0x1D1D1F, dark: 0xECEDEF)
    static let textSecondary = dynamic("textSecondary", light: 0x6E6E73, dark: 0x9BA1AB)
    static let textTertiary = dynamic("textTertiary", light: 0x3A3A3C, dark: 0xC7C7CC)

    // 强调与 AI
    static let accent = dynamic("accent", light: 0x2F6FED, dark: 0x5A8DF2)
    static let accentStrong = dynamic("accentStrong", light: 0x2459C9, dark: 0x7FA6F5)
    static let accentTint = dynamic("accentTint", light: 0xEEF2FF, dark: 0x1E2A44)
    static let accentTintBorder = dynamic("accentTintBorder", light: 0xD9E3FB, dark: 0x2C3D63)
    static let aiTint = dynamic("aiTint", light: 0xF3EEFF, dark: 0x2D2545)
    static let aiText = dynamic("aiText", light: 0x6B4FD8, dark: 0xA894F0)

    // 标签与控件
    static let chipNeutral = dynamic("chipNeutral", light: 0xEDEDF0, dark: 0x34353A)
    static let chipCount = dynamic("chipCount", light: 0xE5E5EA, dark: 0x3A3B40)
    static let dotOff = dynamic("dotOff", light: 0xAEAEB2, dark: 0x636366)
    static let toggleOff = dynamic("toggleOff", light: 0xD1D1D6, dark: 0x4A4B50)
    static let toggleDisabled = dynamic("toggleDisabled", light: 0xE5E5EA, dark: 0x34353A)
    static let knob = dynamic("knob", light: 0xFFFFFF, dark: 0xF2F2F5)

    // 状态
    static let success = dynamic("success", light: 0x1F9D55, dark: 0x3DC47E)
    static let successTint = dynamic("successTint", light: 0xE8F5EE, dark: 0x17301F)
    static let successText = dynamic("successText", light: 0x146C3B, dark: 0x6FD69C)
    static let danger = dynamic("danger", light: 0xD93025, dark: 0xF26B60)

    /// ROM 权限横幅：浅黄底、深黄描边与文字。
    static let warnTint = dynamic("warnTint", light: 0xFFF6E0, dark: 0x3A2F12)
    static let warnBorder = dynamic("warnBorder", light: 0xF1E0B0, dark: 0x5C4A1C)
    static let warnText = dynamic("warnText", light: 0x7A5200, dark: 0xF5C76B)

    // 设备外框、代码块与阴影：两种外观下的深色块
    static let bezel = dynamic("bezel", light: 0x1C1C1E, dark: 0x0A0A0B)
    static let codeDark = dynamic("codeDark", light: 0x1D1D1F, dark: 0x111113)
    static let codeDarkText = dynamic("codeDarkText", light: 0xF2F2F5, dark: 0xF2F2F5)
    static let shadow = dynamic("shadow", light: 0x000000, dark: 0x000000)
    static let shadowDeep = dynamic("shadowDeep", light: 0x101828, dark: 0x101828)

    /// 设备状态点：已连接 / 等待授权。
    static let warning = dynamic("warning", light: 0xE08A00, dark: 0xF5A623)

    /// 日志级别文字色：V / D 偏灰，I 为强调色以外的绿，W / E / F 递进。
    static let logVerbose = dynamic("logVerbose", light: 0x6B7280, dark: 0x9BA1AB)
    static let logDebug = dynamic("logDebug", light: 0x2F6FED, dark: 0x5A8DF2)
    static let logInfo = dynamic("logInfo", light: 0x1E9E5A, dark: 0x3DC47E)
    static let logWarn = dynamic("logWarn", light: 0xE08A00, dark: 0xF5A623)
    static let logError = dynamic("logError", light: 0xD93025, dark: 0xF26B60)
    static let logFatal = dynamic("logFatal", light: 0xA50E6B, dark: 0xE05AB0)

    /// 投屏画面四周与弹出窗口：视频本身是黑底，两种外观一致。
    static let videoBackground = dynamic("videoBackground", light: 0x000000, dark: 0x000000)
    /// 弹出窗口底栏与画面上的文字 / 图标。
    static let videoChrome = dynamic("videoChrome", light: 0x1A1A1A, dark: 0x1A1A1A)
    static let onVideo = dynamic("onVideo", light: 0xFFFFFF, dark: 0xFFFFFF)
    /// 盖在画面上的「正在连接 / 已断开」遮罩。
    static let videoScrim = dynamic("videoScrim", light: 0x000000, dark: 0x000000, alpha: 0.7)
    /// 画面顶部的 AI 提示胶囊（强调色底、白字）。
    static let aiCapsule = dynamic("aiCapsule", light: 0x2F6FED, dark: 0x5A8DF2, alpha: 0.9)

    /// 拖放悬停时盖在画面上的提示层（强调色半透明）。
    static let dropOverlay = dynamic("dropOverlay", light: 0x2F6FED, dark: 0x5A8DF2, alpha: 0.12)

    private static func dynamic(_ name: String, light: UInt32, dark: UInt32, alpha: CGFloat = 1, darkAlpha: CGFloat? = nil) -> Color {
        let color = NSColor(name: NSColor.Name("Tandem.\(name)")) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light, alpha: isDark ? (darkAlpha ?? alpha) : alpha)
        }
        return Color(nsColor: color)
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
    }
}
