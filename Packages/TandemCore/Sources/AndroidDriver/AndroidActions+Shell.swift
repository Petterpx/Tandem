import Foundation
import DeviceCore

extension AndroidActions {
    /// 在设备上执行 shell 命令：设备端 `timeout` 负责超时（到点仍能拿到部分输出），
    /// 本机 runner 超时为设备超时加 5 秒，仅作兜底。非零退出码原样返回，不抛错。
    public func shell(_ command: String, timeout: Duration) async throws -> ShellResult {
        let seconds = Self.wholeSeconds(timeout)
        let args = ["shell", "timeout", String(seconds), "sh", "-c", ShellQuote.quote(command)]
        let result: ProcessResult
        do {
            result = try await adb.run(args, serial: serial, timeout: .seconds(seconds) + .seconds(5))
        } catch let e as DeviceError where e.code == .TIMEOUT {
            throw DeviceError.timeout("shell 命令")
        }
        return ShellResult(
            stdout: result.stdoutString,
            stderr: String(decoding: result.stderr, as: UTF8.self),
            exitCode: result.exitCode,
            timedOut: result.exitCode == 124
        )
    }

    /// Duration 向上取整到整秒，至少 1 秒。
    private static func wholeSeconds(_ d: Duration) -> Int {
        let c = d.components
        let up = c.seconds + (c.attoseconds > 0 ? 1 : 0)
        return max(1, Int(up))
    }
}
