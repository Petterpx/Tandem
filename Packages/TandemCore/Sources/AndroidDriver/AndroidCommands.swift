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

        /// 默认桌面（HOME）的组件。
        static let homeCommand = "cmd package resolve-activity --brief -a android.intent.action.MAIN -c android.intent.category.HOME"

        /// 前台是系统界面（锁屏、通知栏等）时视为读不到前台 App。
        static let systemUIPackage = "com.android.systemui"

        /// `homeCommand` 输出中组件 `/` 之前的包名；解析不出为 nil。
        static func parseHomePackage(_ out: String) -> String? {
            parseLaunchComponent(out).flatMap { $0.split(separator: "/").first.map(String.init) }
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
            // 来自设备输出，进入 shell 前必须严格校验。
            guard let last, last.wholeMatch(of: /[A-Za-z0-9_.$]+\/[A-Za-z0-9_.$]+/) != nil else { return nil }
            return last
        }

        /// 有任一行以 `Error` 开头才算失败；成功时 `am start` 回显的 Intent 可能含 "Error" 字样。
        static func hasErrorLine(_ out: String) -> Bool {
            out.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Error") }
        }
    }

    enum DevSettings {
        static let readCommand = "settings get system show_touches; getprop debug.layout; settings get global stay_on_while_plugged_in; settings get global window_animation_scale"

        /// 逐行解析：显示触摸 / 常亮看整数，布局边界看 `true`（空为未知），倍速 `null` 视为 1。
        static func parse(_ out: String) -> DevOptions {
            let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            func line(_ i: Int) -> String { i < lines.count ? lines[i] : "" }
            func flag(_ i: Int) -> Bool? { Int(line(i)).map { $0 != 0 } }
            let layout = line(1)
            return DevOptions(
                showTouches: flag(0),
                layoutBounds: layout.isEmpty || layout == "null" ? nil : layout == "true",
                stayAwake: flag(2),
                animationScale: Double(line(3)) ?? 1
            )
        }

        static func setCommand(_ o: DevOption) throws -> String {
            switch o {
            case .showTouches(let on): return "settings put system show_touches \(on ? 1 : 0)"
            case .layoutBounds(let on): return "setprop debug.layout \(on); service call activity 1599295570 > /dev/null"
            case .stayAwake(let on): return "settings put global stay_on_while_plugged_in \(on ? 7 : 0)"
            case .animationScale(let v):
                guard DevOption.animationScales.contains(v) else {
                    throw DeviceError(code: .INVALID_ARGUMENT, message: "不支持的动画倍速：\(v)")
                }
                let text = v.compactText
                return ["window_animation_scale", "transition_animation_scale", "animator_duration_scale"]
                    .map { "settings put global \($0) \(text)" }
                    .joined(separator: "; ")
            }
        }
    }

    enum System {
        /// 深色模式与字体缩放分两条命令读：`cmd uimode night` 的输出行数随系统不同，不能按行号取字体缩放。
        static let nightCommand = "cmd uimode night"
        static let fontScaleCommand = "settings get system font_scale"

        /// `Night mode: yes|no`；`auto` 等其它输出为未知。
        static func parseNight(_ out: String) -> Bool? {
            guard let m = out.firstMatch(of: /Night mode:\s*(\w+)/) else { return nil }
            switch m.1 {
            case "yes": return true
            case "no": return false
            default: return nil
            }
        }

        static func parseFontScale(_ out: String) -> Double? {
            Double(out.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        /// `Locales for pkg for user 0 are [zh-CN]` → `zh-CN`；`[]` → 空串；其它为 nil。
        static func parseAppLocales(_ out: String) -> String? {
            guard let m = out.firstMatch(of: /are \[([^\]]*)\]/) else { return nil }
            return String(m.1)
        }

        static func setCommand(_ s: SystemSetting) throws -> String {
            switch s {
            case .darkMode(let on): return "cmd uimode night \(on ? "yes" : "no")"
            case .fontScale(let v):
                guard SystemSetting.fontScales.contains(v) else {
                    throw DeviceError(code: .INVALID_ARGUMENT, message: "不支持的字体缩放：\(v)")
                }
                return "settings put system font_scale \(v.compactText)"
            case .appLocale(let package, let tag):
                let pkg = try PackageName.validate(package)
                guard tag.isEmpty || tag.wholeMatch(of: /[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*/) != nil else {
                    throw DeviceError(code: .INVALID_ARGUMENT, message: "语言标签不合法：\(tag)")
                }
                return "cmd locale set-app-locales \(pkg) --locales \(ShellQuote.quote(tag))"
            }
        }
    }

    enum Install {
        /// 常见安装失败码对应的中文建议；未识别返回 nil。
        static func failureAdvice(_ output: String) -> String? {
            if output.contains("INSTALL_FAILED_VERSION_DOWNGRADE") { return "设备上已有更高版本" }
            if output.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") { return "签名与已安装版本不一致，请先卸载" }
            if output.contains("INSTALL_FAILED_INSUFFICIENT_STORAGE") { return "设备存储空间不足" }
            if output.contains("INSTALL_FAILED_NO_MATCHING_ABIS") { return "APK 不支持该设备的 CPU 架构" }
            if output.contains("INSTALL_PARSE_FAILED_") { return "不是有效的 APK" }
            return nil
        }

        static func tempPath(_ id: UUID) -> String { "/data/local/tmp/tandem_\(id.uuidString).apk" }

        static func installCommand(_ path: String) -> String { "pm install -r -d \(ShellQuote.quote(path))" }

        static func scanCommand(_ path: String) -> String {
            "am broadcast -a android.intent.action.MEDIA_SCANNER_SCAN_FILE -d \(ShellQuote.quote("file://" + path))"
        }

        /// 一条 shell 命令的长度上限（UTF-8 字节），低于 adb 的 64 KB 限制。
        static let scanBatchLimit = 60_000

        /// 各路径的广播以 ` ; ` 连成命令，每条不超过 `limit`；单个超长的广播自成一条。
        static func scanBatches(_ paths: [String], limit: Int = scanBatchLimit) -> [String] {
            var batches: [String] = []
            var current = ""
            for command in paths.map(scanCommand) {
                if !current.isEmpty, current.utf8.count + 3 + command.utf8.count > limit {
                    batches.append(current)
                    current = ""
                }
                current = current.isEmpty ? command : current + " ; " + command
            }
            if !current.isEmpty { batches.append(current) }
            return batches
        }
    }

    enum Logs {
        /// threadtime 行：`MM-dd HH:mm:ss.SSS pid tid L tag: message`。
        /// tag 可含空格与冒号（取最短匹配）；空消息时行尾只有 `tag:`（logcat 会裁掉末尾空格），故空格与消息整体可选。
        private nonisolated(unsafe) static let threadtime =
            /^(\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})\s+(\d+)\s+(\d+)\s+([VDIWEF])\s+(.*?)\s*:(?: (.*))?$/

        /// `Start proc 1234:包名/` 或 `Start proc 1234:包名:进程/`。
        private nonisolated(unsafe) static let startProc = /Start proc (\d+):(.*)/

        /// 解析一行 threadtime；分隔行（`--------- beginning of ...`）与无法识别的行返回 nil。兼容 CRLF。
        static func parse(_ line: String) -> LogEntry? {
            var line = Substring(line)
            while let last = line.unicodeScalars.last, last == "\r" || last == "\n" {
                line = Substring(line.unicodeScalars.dropLast())
            }
            guard let m = line.wholeMatch(of: threadtime),
                  let pid = Int(m.2), let tid = Int(m.3),
                  let level = LogLevel(rawValue: String(m.4)) else { return nil }
            return LogEntry(time: String(m.1), pid: pid, tid: tid, level: level,
                            tag: String(m.5).trimmingCharacters(in: .whitespaces),
                            message: m.6.map(String.init) ?? "")
        }

        /// ActivityManager 的 `Start proc` 记录中属于该包（含 `包名:进程` 形式）的 pid，去重并保持出现顺序。
        static func startProcPids(_ entries: [LogEntry], package: String) -> [Int] {
            var seen = Set<Int>()
            var pids: [Int] = []
            for e in entries where e.tag == "ActivityManager" {
                guard let m = e.message.firstMatch(of: startProc), let pid = Int(m.1) else { continue }
                let rest = m.2
                guard rest.hasPrefix(package), let next = rest.dropFirst(package.count).first,
                      next == "/" || next == ":" else { continue }
                if seen.insert(pid).inserted { pids.append(pid) }
            }
            return pids
        }

        /// 快照只取缓冲末尾的条数：整个缓冲可达数十万行，导出需近 18 秒，逼近超时。
        static let snapshotWindow = 50_000

        static func snapshotCommand(minLevel: LogLevel, lines: Int = snapshotWindow) -> String {
            "logcat -d -v threadtime -t \(lines) " + ShellQuote.quote("*:\(minLevel.rawValue)")
        }

        /// 快照要读的行数：既不按 App 也不按关键字过滤时，最后 N 行就是结果，只读 N 行；否则读整个窗口。
        static func snapshotLines(_ q: LogQuery) -> Int {
            guard q.package == nil, (q.grep ?? "").isEmpty else { return snapshotWindow }
            return min(max(1, q.lines), snapshotWindow)
        }
    }
}
