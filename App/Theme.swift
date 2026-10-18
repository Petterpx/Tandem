import AppKit
import SwiftUI

/// 全部界面颜色（spec §8）：浅色为主，侧栏冷灰、面板近白、投屏画布浅灰加淡点阵，单一强调色 #2F6FED。
/// 每个颜色给出浅色值，深色值由它派生：中性色按明度翻转后压暗，强调 / 状态色略微提亮，随系统外观切换。
enum Theme {
    static let sidebar = dynamic("sidebar", light: 0xEEF0F3, dark: 0x1F2125)
    static let panel = dynamic("panel", light: 0xFBFBFC, dark: 0x26282C)
    static let canvas = dynamic("canvas", light: 0xE8EAED, dark: 0x18191C)
    static let canvasDot = dynamic("canvasDot", light: 0xCFD3D9, dark: 0x2E3136)
    static let accent = dynamic("accent", light: 0x2F6FED, dark: 0x5A8DF2)
    static let textPrimary = dynamic("textPrimary", light: 0x1C1E21, dark: 0xECEDEF)
    static let textSecondary = dynamic("textSecondary", light: 0x6B7280, dark: 0x9BA1AB)
    static let separator = dynamic("separator", light: 0xDADDE2, dark: 0x35383D)
    static let danger = dynamic("danger", light: 0xD93025, dark: 0xF26B60)

    /// 设备状态点：已连接 / 等待授权。
    static let success = dynamic("success", light: 0x1E9E5A, dark: 0x3DC47E)
    static let warning = dynamic("warning", light: 0xE08A00, dark: 0xF5A623)

    /// 投屏画面四周与弹出窗口：视频本身是黑底，两种外观一致。
    static let videoBackground = dynamic("videoBackground", light: 0x000000, dark: 0x000000)
    /// 弹出窗口底栏与画面上的文字 / 图标。
    static let videoChrome = dynamic("videoChrome", light: 0x1A1A1A, dark: 0x1A1A1A)
    static let onVideo = dynamic("onVideo", light: 0xFFFFFF, dark: 0xFFFFFF)
    /// 盖在画面上的「正在连接 / 已断开」遮罩。
    static let videoScrim = dynamic("videoScrim", light: 0x000000, dark: 0x000000, alpha: 0.7)
    /// ROM 权限横幅（黄底黑字，两种外观一致）。
    static let bannerBackground = dynamic("bannerBackground", light: 0xFFD60A, dark: 0xFFD60A, alpha: 0.9)
    static let bannerText = dynamic("bannerText", light: 0x000000, dark: 0x000000)

    private static func dynamic(_ name: String, light: UInt32, dark: UInt32, alpha: CGFloat = 1) -> Color {
        let color = NSColor(name: NSColor.Name("Tandem.\(name)")) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light, alpha: alpha)
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
