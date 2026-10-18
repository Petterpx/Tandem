import Foundation

enum AndroidKeyAction: UInt8, Sendable { case down = 0, up = 1 }
enum AndroidMotionAction: UInt8, Sendable { case down = 0, up = 1, move = 2 }

enum AndroidKeycode {
    static let home: UInt32 = 3
    static let back: UInt32 = 4
    static let dpadUp: UInt32 = 19
    static let dpadDown: UInt32 = 20
    static let dpadLeft: UInt32 = 21
    static let dpadRight: UInt32 = 22
    static let volumeUp: UInt32 = 24
    static let volumeDown: UInt32 = 25
    static let power: UInt32 = 26
    static let tab: UInt32 = 61
    static let enter: UInt32 = 66
    static let del: UInt32 = 67
    static let forwardDel: UInt32 = 112
    static let appSwitch: UInt32 = 187
}

enum PointerId {
    static let mouse: UInt64 = .max
    static let genericFinger: UInt64 = .max - 1
    /// AI 的触点：固定的普通触点 id，人正在拖动时 AI 点按成为第二个触点，不打断人的手势。
    static let ai: UInt64 = 0x7A11
}

/// scrcpy v5.0.1 控制消息，大端序编码（对应 app/src/control_msg.c）。
enum ControlMessage: Equatable, Sendable {
    case injectKeycode(action: AndroidKeyAction, keycode: UInt32, repeat: UInt32, metaState: UInt32)
    case injectText(String)
    case injectTouch(action: AndroidMotionAction, pointerId: UInt64, x: Int32, y: Int32, screenWidth: UInt16, screenHeight: UInt16,
                     pressure: Float, actionButton: UInt32, buttons: UInt32)
    case injectScroll(x: Int32, y: Int32, screenWidth: UInt16, screenHeight: UInt16, hscroll: Float, vscroll: Float, buttons: UInt32)
    case backOrScreenOn(AndroidKeyAction)
    case getClipboard(copyKey: UInt8)
    case setClipboard(sequence: UInt64, text: String, paste: Bool)

    static let injectTextMaxLength = 300
    static let clipboardTextMaxLength = (1 << 18) - 14

    func encoded() -> Data {
        var out = Data()
        switch self {
        case let .injectKeycode(action, keycode, rep, meta):
            out.append(0)
            out.append(action.rawValue)
            out.appendBE(keycode)
            out.appendBE(rep)
            out.appendBE(meta)
        case let .injectText(text):
            out.append(1)
            out.appendString(text, maxLength: Self.injectTextMaxLength)
        case let .injectTouch(action, pointerId, x, y, w, h, pressure, actionButton, buttons):
            out.append(2)
            out.append(action.rawValue)
            out.appendBE(pointerId)
            out.appendPosition(x, y, w, h)
            out.appendBE(Self.floatToU16(pressure))
            out.appendBE(actionButton)
            out.appendBE(buttons)
        case let .injectScroll(x, y, w, h, hscroll, vscroll, buttons):
            out.append(3)
            out.appendPosition(x, y, w, h)
            out.appendBE(UInt16(bitPattern: Self.floatToI16(Self.normalizeScroll(hscroll))))
            out.appendBE(UInt16(bitPattern: Self.floatToI16(Self.normalizeScroll(vscroll))))
            out.appendBE(buttons)
        case let .backOrScreenOn(action):
            out.append(4)
            out.append(action.rawValue)
        case let .getClipboard(copyKey):
            out.append(8)
            out.append(copyKey)
        case let .setClipboard(sequence, text, paste):
            out.append(9)
            out.appendBE(sequence)
            out.append(paste ? 1 : 0)
            out.appendString(text, maxLength: Self.clipboardTextMaxLength)
        }
        return out
    }

    /// 与 scrcpy sc_float_to_u16fp 一致：f * 65536，上限 0xffff。
    private static func floatToU16(_ f: Float) -> UInt16 {
        guard f > 0 else { return 0 }
        let v = f * 65536
        return v >= 65535 ? 0xffff : UInt16(v)
    }

    /// 与 scrcpy sc_float_to_i16fp 一致：f * 32768，上限 0x7fff。
    private static func floatToI16(_ f: Float) -> Int16 {
        let v = f * 32768
        if v.isNaN { return 0 }
        if v >= 32767 { return 0x7fff }
        if v <= -32768 { return Int16.min }
        return Int16(v)
    }

    private static func normalizeScroll(_ f: Float) -> Float {
        min(max(f / 16, -1), 1)
    }
}

private extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendPosition(_ x: Int32, _ y: Int32, _ w: UInt16, _ h: UInt16) {
        appendBE(x)
        appendBE(y)
        appendBE(w)
        appendBE(h)
    }

    /// u32 长度 + UTF-8 字节，按 UTF-8 字符边界截断到 maxLength 字节。
    mutating func appendString(_ text: String, maxLength: Int) {
        var bytes = Array(text.utf8)
        if bytes.count > maxLength {
            var end = maxLength
            // 回退到字符起始处（跳过 10xxxxxx 续字节）
            while end > 0, bytes[end] & 0xC0 == 0x80 { end -= 1 }
            bytes.removeSubrange(end...)
        }
        appendBE(UInt32(bytes.count))
        append(contentsOf: bytes)
    }
}
