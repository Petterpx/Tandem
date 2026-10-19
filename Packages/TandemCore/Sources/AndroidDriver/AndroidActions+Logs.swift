import Foundation
import DeviceCore

extension AndroidActions {
    /// 包的运行中 pid（`pidof`，空格分隔）；未运行时 pidof 非零退出且无输出，返回空数组。
    public func pids(of package: String) async throws -> [Int] {
        let pkg = try PackageName.validate(package)
        let out = try await shellChecked("pidof \(ShellQuote.quote(pkg))").stdout
        return out.split(whereSeparator: \.isWhitespace).compactMap { Int($0) }
    }

    public func logSnapshot(_ q: LogQuery) async throws -> LogSnapshot {
        let package = try q.package.map(PackageName.validate)
        // 显式 self：下面的局部变量 pids 会在较旧的编译器上遮蔽同名方法
        var running: [Int] = []
        if let package { running = try await self.pids(of: package) }
        // 日志正文常含 "not found" / "Unknown command"，不做不支持检测。
        let command = AndroidCommands.Logs.snapshotCommand(minLevel: q.minLevel, lines: AndroidCommands.Logs.snapshotLines(q))
        let raw = try await shellChecked(command, timeout: .seconds(20), detectUnsupported: false).stdout
        var entries = raw.split(whereSeparator: \.isNewline).compactMap { AndroidCommands.Logs.parse(String($0)) }

        var pids: [Int] = []
        if let package {
            // pidof 在前，再补日志里 Start proc 记录到的 pid（进程可能已退出），按出现顺序去重。
            var seen = Set<Int>()
            for pid in running + AndroidCommands.Logs.startProcPids(entries, package: package) where seen.insert(pid).inserted {
                pids.append(pid)
            }
            guard !pids.isEmpty else {
                return LogSnapshot(entries: [], pids: [], note: "缓冲中没有 \(package) 的记录")
            }
            let set = Set(pids)
            entries = entries.filter { set.contains($0.pid) }
        }
        if let grep = q.grep, !grep.isEmpty {
            entries = entries.filter {
                $0.message.localizedCaseInsensitiveContains(grep) || $0.tag.localizedCaseInsensitiveContains(grep)
            }
        }
        return LogSnapshot(entries: Array(entries.suffix(max(0, q.lines))), pids: pids)
    }

    /// 持续输出的 logcat；消费方取消时终止 adb 进程，进程自行退出时流正常结束。
    /// `-T 1`：只从缓冲里最新的一行开始跟随。不加时 logcat 会先重放整个缓冲（真机上数十万行、持续十几秒），
    /// 与日志窗口用快照补上的历史重复；历史一律由 `logSnapshot` 提供。
    public func logStream() throws -> AsyncThrowingStream<LogEntry, any Error> {
        let process = try adb.runner.stream(adb.adb.url, ["-s", serial, "logcat", "-v", "threadtime", "-T", "1"])
        return AsyncThrowingStream { continuation in
            let task = Task {
                for await line in process.lines {
                    if let entry = AndroidCommands.Logs.parse(line) { continuation.yield(entry) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                process.terminate()
            }
        }
    }
}
