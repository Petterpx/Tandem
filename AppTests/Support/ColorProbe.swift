import AppKit
import SwiftUI

/// 在指定外观下读出 SwiftUI 颜色的 sRGB 值，用于断言 Theme 动态色。
enum ColorProbe {
    static func rgba(_ color: Color, dark: Bool) -> (hex: UInt32, alpha: CGFloat) {
        var result: (hex: UInt32, alpha: CGFloat) = (0, 0)
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let c = NSColor(color).usingColorSpace(.sRGB)!
            func byte(_ v: CGFloat) -> UInt32 { UInt32((v * 255).rounded()) }
            result = ((byte(c.redComponent) << 16) | (byte(c.greenComponent) << 8) | byte(c.blueComponent), c.alphaComponent)
        }
        return result
    }
}
