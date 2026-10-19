import Foundation
import DeviceCore

public struct AdbClient: Sendable {
    public let adb: Adb
    let runner: any ProcessRunner

    public init(adb: Adb, runner: any ProcessRunner) {
        self.adb = adb
        self.runner = runner
    }

    public func run(_ args: [String], serial: String? = nil, timeout: Duration = .seconds(10)) async throws -> ProcessResult {
        let full = serial.map { ["-s", $0] + args } ?? args
        return try await runner.run(adb.url, full, timeout: timeout)
    }

    public func shell(_ serial: String, _ command: String, timeout: Duration = .seconds(10)) async throws -> String {
        try checked(await run(["shell", command], serial: serial, timeout: timeout)).stdoutString
    }

    /// `adb -s <serial> exec-out <args…>`：二进制安全地取回 stdout（如 screencap）。
    public func execOut(_ serial: String, _ args: [String], timeout: Duration = .seconds(15)) async throws -> Data {
        try checked(await run(["exec-out"] + args, serial: serial, timeout: timeout)).stdout
    }

    public func getprop(_ serial: String, _ key: String) async throws -> String {
        try checked(await run(["shell", "getprop", key], serial: serial)).stdoutString
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func checked(_ result: ProcessResult) throws -> ProcessResult {
        guard result.exitCode == 0 else {
            let err = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = err.isEmpty ? result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) : err
            throw DeviceError.connectionFailed(detail)
        }
        return result
    }
}
