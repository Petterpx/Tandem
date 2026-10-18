import DeviceCore
import Foundation

/// InputAction → scrcpy 控制消息。
enum InputMapper {
    enum Output: Equatable {
        case messages([ControlMessage])
        /// 非可打印 ASCII 文本：走 setClipboard(paste: true)。
        case paste(String)
    }

    static let scrollLimit = 16.0

    static func map(_ action: InputAction, width: Int, height: Int) -> Output {
        switch action {
        case let .touch(phase, p, pointer):
            let motion: AndroidMotionAction
            switch phase {
            case .down: motion = .down
            case .move: motion = .move
            case .up: motion = .up
            }
            let pointerId = switch pointer {
            case .finger: PointerId.genericFinger
            case .ai: PointerId.ai
            }
            return .messages([.injectTouch(action: motion, pointerId: pointerId,
                                           x: pixel(p.x, width), y: pixel(p.y, height),
                                           screenWidth: UInt16(clamping: width), screenHeight: UInt16(clamping: height),
                                           pressure: phase == .up ? 0 : 1.0, actionButton: 0, buttons: 0)])
        case let .scroll(p, dx, dy):
            return .messages([.injectScroll(x: pixel(p.x, width), y: pixel(p.y, height),
                                            screenWidth: UInt16(clamping: width), screenHeight: UInt16(clamping: height),
                                            hscroll: Float(clampScroll(dx)), vscroll: Float(clampScroll(dy)), buttons: 0)])
        case .key(.back):
            return .messages([.backOrScreenOn(.down), .backOrScreenOn(.up)])
        case let .key(key):
            let code = keycode(key)
            return .messages([.injectKeycode(action: .down, keycode: code, repeat: 0, metaState: 0),
                              .injectKeycode(action: .up, keycode: code, repeat: 0, metaState: 0)])
        case let .text(text):
            guard text.unicodeScalars.allSatisfy({ (0x20...0x7e).contains($0.value) }) else { return .paste(text) }
            // 纯 ASCII：一个字符一个字节，按 300 字节分段。
            let chars = Array(text)
            let chunks = stride(from: 0, to: chars.count, by: ControlMessage.injectTextMaxLength).map {
                ControlMessage.injectText(String(chars[$0..<min($0 + ControlMessage.injectTextMaxLength, chars.count)]))
            }
            return .messages(chunks)
        }
    }

    /// clamp(Int32(v * size), 0, size - 1)
    static func pixel(_ normalized: Double, _ size: Int) -> Int32 {
        let v = normalized * Double(size)
        guard v.isFinite else { return v > 0 ? Int32(clamping: size - 1) : 0 }
        return Int32(min(max(v, 0), Double(max(size - 1, 0))))
    }

    private static func clampScroll(_ v: Double) -> Double {
        v.isNaN ? 0 : min(max(v, -scrollLimit), scrollLimit)
    }

    static func keycode(_ key: DeviceKey) -> UInt32 {
        switch key {
        case .back: AndroidKeycode.back
        case .home: AndroidKeycode.home
        case .recents: AndroidKeycode.appSwitch
        case .volumeUp: AndroidKeycode.volumeUp
        case .volumeDown: AndroidKeycode.volumeDown
        case .power: AndroidKeycode.power
        case .enter: AndroidKeycode.enter
        case .delete: AndroidKeycode.del
        case .forwardDelete: AndroidKeycode.forwardDel
        case .tab: AndroidKeycode.tab
        case .up: AndroidKeycode.dpadUp
        case .down: AndroidKeycode.dpadDown
        case .left: AndroidKeycode.dpadLeft
        case .right: AndroidKeycode.dpadRight
        }
    }
}
