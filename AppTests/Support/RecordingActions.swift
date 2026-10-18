import DeviceCore
import Foundation
import os

/// 记录每次调用的设备操作替身：调用记为「方法名 参数」，各方法的返回值或错误可配置。
final class RecordingActions: DeviceActions, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []

    var calls: [String] { lock.withLock { _calls } }

    /// 方法名（如 "forceStop"、"shell"）→ 要抛出的错误。
    var errors: [String: any Error] = [:]
    var networkStateResult = NetworkState(wifi: true, data: true, airplane: false)
    var setNetworkResult: NetworkState?
    var foregroundAppResult = AppInfo(package: "com.demo")
    var devOptionsResult = DevOptions()
    var systemSettingsResult = SystemSettings(appLocaleSupported: true)
    var shellResult = ShellResult(stdout: "", stderr: "", exitCode: 0)
    /// 最近一次 shell 调用传入的超时。
    private(set) var shellTimeout: Duration?
    /// 读取网络状态前执行的挂起点（可让某台设备的读取保持挂起，测过期结果）。
    var networkStateHook: (@Sendable () async -> Void)?
    /// 读取前台 App 前执行的挂起点（测读取进行中的界面状态）。
    var foregroundAppHook: (@Sendable () async -> Void)?

    // 文件与日志
    var listDirectoryResult: [RemoteFile] = []
    /// 列目录前执行的挂起点（参数为路径），可让某次列目录保持挂起，测过期结果。
    /// 按路径指定的列目录结果；没有时用 listDirectoryResult。
    var listDirectoryResults: [String: [RemoteFile]] = [:]
    var listDirectoryHook: (@Sendable (String) async -> Void)?
    /// stat 视为存在的设备路径；其余路径 stat 返回 nil。
    var existingPaths: Set<String> = []
    var installResult: String? = "com.demo"
    var pidsResult: [Int] = []
    var logSnapshotResult = LogSnapshot(entries: [], pids: [])
    var logStreamEntries: [LogEntry] = []
    /// push / pull / install 开始时依次回调的进度。
    var progressChunks: [TransferProgress] = []
    /// 设置后 push / pull / install 在回调进度后挂起，直到闸门放行一次（响应任务取消）。
    var transferGate: TransferGate?

    private func record(_ call: String, method: String) throws {
        lock.withLock { _calls.append(call) }
        if let error = errors[method] { throw error }
    }

    func screenshot() async throws -> Data { try record("screenshot", method: "screenshot"); return Data() }
    func uiTree() async throws -> UITree {
        try record("uiTree", method: "uiTree")
        return UITree(screen: CGSize(width: 1080, height: 2400), elements: [])
    }
    func networkState() async throws -> NetworkState {
        try record("networkState", method: "networkState")
        if let networkStateHook { await networkStateHook() }
        return networkStateResult
    }
    func setNetwork(_ kind: NetworkKind, on: Bool) async throws -> NetworkState {
        try record("setNetwork \(kind.rawValue) \(on)", method: "setNetwork")
        if let setNetworkResult { return setNetworkResult }
        var s = networkStateResult
        switch kind {
        case .wifi: s.wifi = on
        case .data: s.data = on
        case .airplane: s.airplane = on
        }
        return s
    }
    func foregroundApp() async throws -> AppInfo {
        try record("foregroundApp", method: "foregroundApp")
        if let foregroundAppHook { await foregroundAppHook() }
        return foregroundAppResult
    }
    func launchApp(_ package: String) async throws { try record("launchApp \(package)", method: "launchApp") }
    func forceStop(_ package: String) async throws { try record("forceStop \(package)", method: "forceStop") }
    func clearData(_ package: String) async throws { try record("clearData \(package)", method: "clearData") }
    func uninstall(_ package: String) async throws { try record("uninstall \(package)", method: "uninstall") }
    func openURL(_ url: String) async throws { try record("openURL \(url)", method: "openURL") }
    func devOptions() async throws -> DevOptions { try record("devOptions", method: "devOptions"); return devOptionsResult }
    func setDevOption(_ option: DevOption) async throws { try record("setDevOption \(option)", method: "setDevOption") }
    func systemSettings(appPackage: String?) async throws -> SystemSettings {
        try record("systemSettings \(appPackage ?? "-")", method: "systemSettings")
        return systemSettingsResult
    }
    func setSystem(_ setting: SystemSetting) async throws { try record("setSystem \(setting)", method: "setSystem") }
    func openSystemLocaleSettings() async throws { try record("openSystemLocaleSettings", method: "openSystemLocaleSettings") }
    func shell(_ command: String, timeout: Duration) async throws -> ShellResult {
        lock.withLock { shellTimeout = timeout }
        try record("shell \(command)", method: "shell")
        return shellResult
    }

    func listDirectory(_ path: String) async throws -> [RemoteFile] {
        try record("listDirectory \(path)", method: "listDirectory")
        if let listDirectoryHook { await listDirectoryHook(path) }
        return listDirectoryResults[path] ?? listDirectoryResult
    }
    func stat(_ path: String) async throws -> RemoteFile? {
        try record("stat \(path)", method: "stat")
        guard existingPaths.contains(path) else { return nil }
        return RemoteFile(name: (path as NSString).lastPathComponent, path: path, kind: .file, size: 1, modified: Date())
    }
    func push(_ local: URL, to remote: String, progress: @escaping ProgressHandler) async throws {
        try record("push \(local.lastPathComponent) \(remote)", method: "push")
        try await transfer(progress)
    }
    func pull(_ remote: String, to local: URL, progress: @escaping ProgressHandler) async throws {
        try record("pull \(remote) \(local.lastPathComponent)", method: "pull")
        try await transfer(progress)
        try Data().write(to: local)
    }
    func install(apk: URL, progress: @escaping ProgressHandler) async throws -> String? {
        try record("install \(apk.lastPathComponent)", method: "install")
        try await transfer(progress)
        return installResult
    }
    func mediaScan(_ remotePaths: [String]) async throws {
        try record("mediaScan \(remotePaths.joined(separator: ","))", method: "mediaScan")
    }
    func pids(of package: String) async throws -> [Int] { try record("pids \(package)", method: "pids"); return pidsResult }
    func logSnapshot(_ query: LogQuery) async throws -> LogSnapshot {
        try record("logSnapshot \(query.package ?? "-")", method: "logSnapshot")
        return logSnapshotResult
    }
    func logStream() throws -> AsyncThrowingStream<LogEntry, any Error> {
        try record("logStream", method: "logStream")
        let entries = logStreamEntries
        return AsyncThrowingStream { c in
            for e in entries { c.yield(e) }
            c.finish()
        }
    }

    private func transfer(_ progress: ProgressHandler) async throws {
        for p in progressChunks { progress(p) }
        if let transferGate { try await transferGate.wait() }
    }
}

/// 传输替身的闸门：每次 release 放行一个等待者；等待中任务被取消时抛 CancellationError。
final class TransferGate: Sendable {
    private let permits = OSAllocatedUnfairLock(initialState: 0)

    func release() { permits.withLock { $0 += 1 } }

    func wait() async throws {
        while true {
            let passed = permits.withLock { n -> Bool in
                guard n > 0 else { return false }
                n -= 1
                return true
            }
            if passed { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
