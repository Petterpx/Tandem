import Foundation
import os

/// 「添加到 Claude Code」（spec §5.4）：生成命令与 JSON 配置，并经登录 shell 执行。
/// 必须用 user 作用域：默认的 local 作用域绑定当前目录，从 App 里执行毫无意义。
enum ClaudeSetup {
    /// 单引号包裹，内部的 `'` 写成 `'\''`。
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    static func addCommand(mcpPath: String) -> String {
        "claude mcp add --scope user tandem -- \(shellQuote(mcpPath))"
    }

    /// 先移除旧条目（忽略失败，用于更新路径），再添加。
    static func installScript(mcpPath: String) -> String {
        "claude mcp remove --scope user tandem >/dev/null 2>&1; " + addCommand(mcpPath: mcpPath)
    }

    /// 供其他 MCP 客户端使用的配置；用 JSONSerialization 生成，路径中的引号、反斜杠都能正确转义。
    static func jsonConfig(mcpPath: String) -> String {
        let object = ["mcpServers": ["tandem": ["command": mcpPath]]]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// `claude mcp` 卡住（例如等待输入或网络）时的最长等待。
    static let installTimeout: Duration = .seconds(60)

    /// 经登录 shell 执行（GUI App 的 PATH 里通常没有 `claude`），stdout 与 stderr 合并返回。
    static func install(mcpPath: String) async -> (ok: Bool, output: String) {
        await run(executable: "/bin/zsh", arguments: ["-lc", installScript(mcpPath: mcpPath)], timeout: installTimeout)
    }

    /// 执行命令，stdout 与 stderr 合并返回；标准输入接 /dev/null，超过 `timeout` 就终止并报告超时。
    static func run(executable: String, arguments: [String], timeout: Duration) async -> (ok: Bool, output: String) {
        await withCheckedContinuation { continuation in
            // 超时与正常结束谁先到就用谁的结果
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let finish: @Sendable (Bool, String) -> Void = { ok, output in
                let first = resumed.withLock { done in
                    defer { done = true }
                    return !done
                }
                if first { continuation.resume(returning: (ok, output)) }
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            // 不继承 App 的标准输入：等待输入的命令立即读到 EOF，而不是一直挂着
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
            } catch {
                finish(false, error.localizedDescription)
                return
            }
            let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                // 即使 zsh 已退出，子进程仍可能占着管道：超时一律结束（finish 幂等）
                if process.isRunning { process.terminate() }
                finish(false, "执行超时（\(Int(seconds.rounded())) 秒），已终止")
            }
            // 读管道到结束会阻塞，放到后台线程；先读完再等退出，避免输出过多时管道写满卡住。
            // 超时后若有子进程仍占着管道，这个线程会等到它退出，结果被忽略。
            DispatchQueue.global().async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                finish(process.terminationStatus == 0, output)
            }
        }
    }
}
