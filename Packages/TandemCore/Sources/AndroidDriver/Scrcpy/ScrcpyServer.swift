import DeviceCore
import Foundation

/// scrcpy-server v5.0.1 启动参数。
public struct ScrcpyLaunchOptions: Equatable, Sendable {
    public var scid: UInt32
    public var maxSize: Int
    public var bitRate: Int
    public var maxFps: Int

    static let serverVersion = "5.0.1"
    static let devicePath = "/data/local/tmp/scrcpy-server.jar"

    public init(scid: UInt32, maxSize: Int, bitRate: Int, maxFps: Int) {
        self.scid = scid
        self.maxSize = maxSize
        self.bitRate = bitRate
        self.maxFps = maxFps
    }

    public static func `for`(_ kind: ConnectionKind, scid: UInt32) -> Self {
        switch kind {
        case .usb: Self(scid: scid, maxSize: 1920, bitRate: 8_000_000, maxFps: 60)
        case .wifi: Self(scid: scid, maxSize: 1280, bitRate: 4_000_000, maxFps: 60)
        }
    }

    public var socketName: String { String(format: "scrcpy_%08x", scid) }

    public func serverCommand() -> [String] {
        [
            "CLASSPATH=\(Self.devicePath)", "app_process", "/", "com.genymobile.scrcpy.Server", Self.serverVersion,
            String(format: "scid=%08x", scid), "log_level=info", "audio=false", "video_codec=h264",
            "max_size=\(maxSize)", "video_bit_rate=\(bitRate)", "max_fps=\(maxFps)",
            "tunnel_forward=true", "clipboard_autosync=true",
        ]
    }
}

/// 已启动的服务端：连接、服务端日志（stdout+stderr 按行）与清理函数。
public struct LaunchedServer: Sendable {
    public var connection: ScrcpyConnection
    public var logs: AsyncStream<String>
    /// 终止进程、关闭 socket、移除 forward。
    public var stop: @Sendable () async -> Void

    public init(connection: ScrcpyConnection, logs: AsyncStream<String>, stop: @escaping @Sendable () async -> Void) {
        self.connection = connection
        self.logs = logs
        self.stop = stop
    }
}

public protocol ScrcpyLauncher: Sendable {
    func launch(serial: String, options: ScrcpyLaunchOptions) async throws -> LaunchedServer
}

/// 通过 adb push + forward + shell app_process 启动 scrcpy-server。
public struct AdbScrcpyLauncher: ScrcpyLauncher {
    private let adb: AdbClient
    private let runner: any ProcessRunner
    private let serverJar: URL
    private let connect: @Sendable (UInt16) async throws -> any ByteStream

    public init(adb: AdbClient, runner: any ProcessRunner, serverJar: URL) {
        self.init(adb: adb, runner: runner, serverJar: serverJar, connect: { try await TCPByteStream.connect(port: $0) })
    }

    init(adb: AdbClient, runner: any ProcessRunner, serverJar: URL, connect: @escaping @Sendable (UInt16) async throws -> any ByteStream) {
        self.adb = adb
        self.runner = runner
        self.serverJar = serverJar
        self.connect = connect
    }

    public func launch(serial: String, options: ScrcpyLaunchOptions) async throws -> LaunchedServer {
        try Self.check(await adb.run(["push", serverJar.path, ScrcpyLaunchOptions.devicePath], serial: serial, timeout: .seconds(30)),
                       "推送 scrcpy-server 失败")

        let forward = try Self.check(await adb.run(["forward", "tcp:0", "localabstract:\(options.socketName)"], serial: serial),
                                     "建立端口转发失败")
        guard let port = UInt16(forward.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DeviceError.connectionFailed("无法解析转发端口：\(forward.stdoutString)")
        }
        // 清理放在独立 Task 里：launch 被取消时也要真正执行（ProcessRunner 会因取消终止子进程）。
        let removeForward: @Sendable () async -> Void = { [adb] in
            await Task { _ = try? await adb.run(["forward", "--remove", "tcp:\(port)"], serial: serial) }.value
        }

        let process: any RunningProcess
        do {
            process = try runner.stream(adb.adb.url, ["-s", serial, "shell"] + options.serverCommand())
        } catch {
            await removeForward()
            throw DeviceError.connectionFailed("启动 scrcpy-server 失败：\(error)")
        }

        let connection: ScrcpyConnection
        do {
            connection = try await ScrcpyConnection.open(port: port, connect: connect)
        } catch {
            process.terminate()
            await removeForward()
            throw error
        }

        return LaunchedServer(connection: connection, logs: process.lines, stop: {
            process.terminate()
            connection.video.close()
            connection.control.close()
            await removeForward()
        })
    }

    @discardableResult
    private static func check(_ result: ProcessResult, _ what: String) throws -> ProcessResult {
        guard result.exitCode == 0 else {
            let err = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = err.isEmpty ? result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines) : err
            throw DeviceError.connectionFailed(detail.isEmpty ? what : "\(what)：\(detail)")
        }
        return result
    }
}

enum ScrcpyLog {
    static func isInjectPermissionError(_ line: String) -> Bool {
        line.contains("INJECT_EVENTS")
    }
}
