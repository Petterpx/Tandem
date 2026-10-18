import Foundation

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

    /// 经登录 shell 执行（GUI App 的 PATH 里通常没有 `claude`），stdout 与 stderr 合并返回。
    static func install(mcpPath: String) async -> (ok: Bool, output: String) {
        let script = installScript(mcpPath: mcpPath)
        return await withCheckedContinuation { continuation in
            // 读管道到结束会阻塞，放到后台线程；先读完再等退出，避免输出过多时管道写满卡住。
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-lc", script]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: (false, error.localizedDescription))
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: (process.terminationStatus == 0, output))
            }
        }
    }
}
