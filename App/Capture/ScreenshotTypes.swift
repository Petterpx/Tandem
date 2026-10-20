import AppKit

/// 截图画质：普通取投屏最新帧，高清走 screencap（无损 PNG）。
enum ScreenshotQuality: Equatable, Sendable {
    case standard, lossless

    /// 按住 ⌥ 为高清。
    init(modifiers: NSEvent.ModifierFlags) {
        self = modifiers.contains(.option) ? .lossless : .standard
    }

    /// 操作记录里的标题。
    var logTitle: String { self == .lossless ? "高清截图" : "截图" }
}

/// 截图的实际来源。
enum ScreenshotSource: Equatable, Sendable {
    case mirrorFrame, screencap

    var label: String { self == .mirrorFrame ? "投屏画质" : "无损" }
}

enum ScreenshotText {
    /// 提示条副文案；尺寸未知时省去第一段。
    static func note(width: Int?, height: Int?, source: ScreenshotSource) -> String {
        var parts: [String] = []
        if let width, let height { parts.append("\(width)×\(height)") }
        parts.append(source.label)
        parts.append("已复制到剪贴板")
        return parts.joined(separator: " · ")
    }
}
