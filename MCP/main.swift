import Foundation
import ControlProtocol
import MCPBridge

/// 拉起 App 失败（`open` 退出码非 0）。
struct LaunchError: Error {
    var status: Int32
}

// 客户端关闭 stdout 后写入时返回 EPIPE 抛错，而不是被 SIGPIPE 杀掉
signal(SIGPIPE, SIG_IGN)

let socketPath = ControlPaths.socketURL(home: FileManager.default.homeDirectoryForCurrentUser).path
// 自身位于 Tandem.app/Contents/MacOS/tandem-mcp，向上三级即 Tandem.app
let appURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let serverVersion = Bundle(url: appURL)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

let options = BridgeOptions(
    connect: { try UnixSocketConnection.connect(path: socketPath) },
    launchApp: {
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-a", appURL.path, "--args", "--background"]
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else { throw LaunchError(status: open.terminationStatus) }
    },
    serverVersion: serverVersion)

await MCPBridge(client: StdioChannel(), options: options).run()
