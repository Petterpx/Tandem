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

    enum Apps {
        /// 前台 Activity 所在行。Android 12 的三星机型只输出 `  ResumedActivity: ...`，
        /// 不含 `mResumedActivity` / `topResumedActivity`，因此一并匹配行首的 `ResumedActivity`。
        static let foregroundCommand = "dumpsys activity activities | grep -E 'topResumedActivity|mResumedActivity|^ +ResumedActivity'"

        /// 取第一处 `u0 包名/Activity`；以 `.` 开头的 Activity 补全为 `包名 + Activity`。
        static func parseForeground(_ out: String) -> (package: String, activity: String)? {
            guard let m = out.firstMatch(of: /u\d+ ([A-Za-z0-9_.]+)\/([A-Za-z0-9_.$]+)/) else { return nil }
            let package = String(m.1)
            var activity = String(m.2)
            if activity.hasPrefix(".") { activity = package + activity }
            return (package, activity)
        }

        static func parseVersionName(_ out: String) -> String? {
            guard let m = out.firstMatch(of: /versionName=(\S+)/) else { return nil }
            return String(m.1)
        }

        /// `resolve-activity --brief` 的最后一个非空行，必须含 `/`。
        static func parseLaunchComponent(_ out: String) -> String? {
            let last = out.split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }
            guard let last, last.contains("/") else { return nil }
            return last
        }
    }
}
