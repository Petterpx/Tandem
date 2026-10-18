import AppKit
import DeviceCore

enum KeyCommand: Equatable {
    case input(InputAction)
    case pasteFromMac
}

enum KeyMapping {
    /// 返回 nil 表示交给输入法 / insertText。
    static func command(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> KeyCommand? {
        // 方向键带 .numericPad/.function，Caps Lock 也在设备无关掩码内，只比较这四个修饰键。
        let mods = modifiers.intersection([.command, .shift, .option, .control])
        if mods.isEmpty {
            switch keyCode {
            case 36: return .input(.key(.enter))
            case 51: return .input(.key(.delete))
            case 117: return .input(.key(.forwardDelete))
            case 48: return .input(.key(.tab))
            case 53: return .input(.key(.back))
            case 123: return .input(.key(.left))
            case 124: return .input(.key(.right))
            case 125: return .input(.key(.down))
            case 126: return .input(.key(.up))
            default: return nil
            }
        }
        if mods == .command {
            switch keyCode {
            case 4: return .input(.key(.home))
            case 1: return .input(.key(.recents))
            case 35: return .input(.key(.power))
            case 126: return .input(.key(.volumeUp))
            case 125: return .input(.key(.volumeDown))
            case 9: return .pasteFromMac
            default: return nil
            }
        }
        return nil
    }
}
