import Foundation
import DeviceCore

/// Android 快捷操作用到的 shell 命令与输出解析（纯函数，便于测试）。
enum AndroidCommands {
    enum Network {
        static let readCommand = "settings get global wifi_on; settings get global mobile_data; settings get global airplane_mode_on"

        /// 逐行解析：`0` 为关，其它整数为开，`null`、空或非数字为未知。
        static func parseState(_ out: String) -> NetworkState {
            let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            func value(_ i: Int) -> Bool? {
                guard i < lines.count, let n = Int(lines[i]) else { return nil }
                return n != 0
            }
            return NetworkState(wifi: value(0), data: value(1), airplane: value(2))
        }

        static func setCommand(_ kind: NetworkKind, on: Bool) -> String {
            let verb = on ? "enable" : "disable"
            switch kind {
            case .wifi: return "svc wifi \(verb)"
            case .data: return "svc data \(verb)"
            case .airplane: return "cmd connectivity airplane-mode \(verb)"
            }
        }
    }
}
