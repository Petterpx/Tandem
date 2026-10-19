import ControlProtocol
import DeviceCore
import Foundation

/// 日志与文件传输工具（spec §4）：参数范围在这里校验，路径规则由 AICommands 与核心层校验。
extension ToolRegistry {
    private static let logLevels = LogLevel.allCases.map(\.rawValue)
    private static let logLines = 1...2000
    private static let defaultLogLines = 200

    /// 传输超时的计费单位与上限：每 10 MB（10 × 1024 × 1024 字节）加 10 秒，最多 10 分钟。
    private static let transferBlock: Int64 = 10 * 1024 * 1024
    private static let maxTransferSeconds = 600
    /// 累计大小达到此值时超时已封顶（30 + 10 × 57 = 600 秒），无需继续遍历。
    private static let sizeCap = Int64((maxTransferSeconds - 30) / 10) * transferBlock
    /// 遍历文件夹最多访问的条目数，超过即按封顶处理，避免海量小文件卡住主线程。
    static let defaultEntryCap = 20_000

    static func fileTools(_ c: AICommands) -> [Tool] {
        [
            Tool(
                name: "get_logs",
                description: "读取设备日志（logcat 缓冲区的最近内容），首行注明过滤条件与 pid。给出 app 时只含该 App 进程的日志。"
                    + "level 为最低级别，默认 V；lines 为返回的最近行数，1 到 2000，默认 200；总长超过 64 KB 截断并注明。",
                properties: [
                    "app": string("App 包名；省略则不按 App 过滤"),
                    "level": enumeration(logLevels, "最低日志级别，默认 V"),
                    "grep": string("只保留包含该文字的行（忽略大小写）"),
                    "lines": integer("返回的最近行数，1 到 2000，默认 200"),
                ],
                required: [], capability: .logs,
                run: { a, d in
                    let app = try a.nonEmptyString("app")
                    let level = try a.string("level").map { raw -> LogLevel in
                        guard let level = LogLevel(rawValue: raw) else {
                            throw invalid("参数 level 应为 " + logLevels.joined(separator: "、") + " 之一")
                        }
                        return level
                    }
                    let lines = try a.int("lines", in: logLines, default: defaultLogLines)
                    return .text(
                        try await c.getLogs(
                            d, app: app, level: level ?? .verbose, grep: try a.nonEmptyString("grep"), lines: lines))
                }),
            Tool(
                name: "push_file",
                description: "把 Mac 上的文件或文件夹推送到设备。dest 为设备路径，以 / 结尾视为目录，默认 /sdcard/Download/；"
                    + "同名自动改名，返回设备上的实际路径。超时 30 秒，每 10 MB 加 10 秒，最多 10 分钟。",
                properties: [
                    "path": string("Mac 上的绝对路径，文件须存在"), "dest": string("设备路径，默认 /sdcard/Download/"),
                ],
                required: ["path"], capability: .files,
                run: { a, d in
                    .text(
                        try await c.pushFile(
                            d, path: try a.requiredNonEmptyString("path"), dest: try a.nonEmptyString("dest")))
                }),
            Tool(
                name: "pull_file",
                description: "把设备上的文件或文件夹拉取到 Mac 的拉取目录（默认 ~/Downloads）。dest 为拉取目录下的相对子目录，"
                    + "不得跳出拉取目录；同名自动改名，返回 Mac 上的绝对路径。超时 10 分钟。",
                properties: [
                    "path": string("设备上的绝对路径"), "dest": string("拉取目录下的相对子目录，默认拉取目录本身"),
                ],
                required: ["path"], capability: .files,
                run: { a, d in
                    .text(
                        try await c.pullFile(
                            d, path: try a.requiredNonEmptyString("path"), dest: try a.nonEmptyString("dest")))
                }),
            Tool(
                name: "install_app",
                description: "安装 Mac 上的 APK 文件，返回包名与「安装成功」。超时 30 秒，每 10 MB 加 10 秒，最多 10 分钟。",
                properties: ["path": string("Mac 上 .apk 文件的绝对路径")],
                required: ["path"], capability: .apps,
                run: { a, d in .text(try await c.installApp(d, path: try a.requiredNonEmptyString("path"))) }),
        ]
    }

    /// push_file / install_app 的超时：30 秒加每 10 MB（向上取整）10 秒，最多 10 分钟；读不到大小按 30 秒。
    static func transferTimeout(arguments: [String: JSONValue], entryCap: Int = defaultEntryCap) -> Duration {
        guard let path = arguments["path"]?.stringValue, path.hasPrefix("/"), let size = localSize(path, entryCap: entryCap)
        else {
            return .seconds(30)
        }
        let blocks = size / transferBlock + (size % transferBlock == 0 ? 0 : 1)
        // 先在 Int64 里封顶，避免超大目录乘法溢出
        return .seconds(min(30 + 10 * min(blocks, Int64(maxTransferSeconds)), Int64(maxTransferSeconds)))
    }

    /// 本地文件或文件夹的总字节数；不存在或读不到返回 nil。文件夹内的符号链接不跟随（避免环），按链接本身不计大小。
    /// 累计达到 sizeCap 即停止；访问条目超过 entryCap 返回 Int64.max（按封顶处理）。
    static func localSize(_ path: String, entryCap: Int = defaultEntryCap) -> Int64? {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        guard let top = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        if top.isDirectory != true { return Int64(top.fileSize ?? 0) }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return nil }
        var total: Int64 = 0, visited = 0
        for case let file as URL in walker {
            visited += 1
            if visited > entryCap { return .max }
            guard let v = try? file.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.fileSize ?? 0)
            if total >= sizeCap { return total }
        }
        return total
    }
}
