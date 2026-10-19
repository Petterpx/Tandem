import Foundation

/// adb server 的监听端口：读 `ADB_SERVER_SOCKET`（`tcp:<port>` 或 `tcp:<host>:<port>`），缺省 5037。
public enum AdbServerEndpoint {
    public static let defaultPort: UInt16 = 5037

    public static func port(environment: [String: String] = ProcessInfo.processInfo.environment) -> UInt16 {
        guard let value = environment["ADB_SERVER_SOCKET"], value.hasPrefix("tcp:"),
              let last = value.dropFirst(4).split(separator: ":", omittingEmptySubsequences: false).last,
              let port = UInt16(last), port > 0
        else { return defaultPort }
        return port
    }
}
