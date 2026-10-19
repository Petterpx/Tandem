import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct AICommandsFilesTests {
    private let pixel = AIEnv.pixel

    private func env() -> (AIEnv, RecordingActions) {
        let actions = RecordingActions()
        return (AIEnv(actions: actions, hasSession: false, sleep: { _ in }), actions)
    }

    private func asyncCode(_ body: () async throws -> Void) async -> DeviceError? {
        do { try await body() } catch { return error as? DeviceError }
        return nil
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-t16-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func file(_ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(repeating: 0x41, count: 4).write(to: url)
        return url
    }

    private func entry(_ message: String, pid: Int = 10) -> LogEntry {
        LogEntry(time: "10-18 12:00:00.123", pid: pid, tid: pid + 1, level: .info, tag: "Tag", message: message)
    }

    // MARK: get_logs

    @Test func getLogsFormat() async throws {
        let (e, actions) = env()
        actions.logSnapshotResult = LogSnapshot(entries: [entry("hello")], pids: [10, 11], note: "附注")
        let text = try await e.commands.getLogs(pixel, app: "com.demo", level: .info, grep: "he", lines: 50)
        let lines = text.split(separator: "\n").map(String.init)
        #expect(lines[0] == "# app=com.demo level=I grep=he pids=10,11 lines=50")
        #expect(lines[1] == "# 附注")
        #expect(lines[2] == "10-18 12:00:00.123 10 11 I Tag: hello")
        #expect(actions.logQueries == [LogQuery(package: "com.demo", minLevel: .info, grep: "he", lines: 50)])
        // 成功不写记录
        #expect(e.log.entries.isEmpty)
    }

    @Test func getLogsHeaderDefaults() async throws {
        let (e, _) = env()
        let text = try await e.commands.getLogs(pixel, app: nil, level: .verbose, grep: nil, lines: 200)
        #expect(text == "# app=all level=V grep=- pids=- lines=200\n")
    }

    @Test func getLogsTruncated() async throws {
        let (e, actions) = env()
        let big = String(repeating: "x", count: 1000)
        actions.logSnapshotResult = LogSnapshot(entries: (0..<70).map { _ in entry(big) }, pids: [])
        let text = try await e.commands.getLogs(pixel, app: nil, level: .verbose, grep: nil, lines: 200)
        #expect(text.utf8.count <= 64 * 1024)
        #expect(text.contains("已截断"))
    }

    @Test func getLogsWorksWhenLocked() async throws {
        let (e, _) = env()
        e.locks.setLocked(pixel.id, true)
        _ = try await e.commands.getLogs(pixel, app: nil, level: .verbose, grep: nil, lines: 10)
    }

    @Test func getLogsFailureIsRecorded() async throws {
        let (e, actions) = env()
        actions.errors["logSnapshot"] = DeviceError(code: .TIMEOUT, message: "超时")
        let error = await asyncCode { _ = try await e.commands.getLogs(pixel, app: nil, level: .verbose, grep: nil, lines: 10) }
        #expect(error?.code == .TIMEOUT)
        #expect(e.log.entries.first?.title == "get_logs")
    }

    // MARK: push_file / install_app

    @Test func pushFilePushesAndRecords() async throws {
        let (e, actions) = env()
        let dir = try tempDir()
        let local = try file("a.jpg", in: dir)
        let text = try await e.commands.pushFile(pixel, path: local.path, dest: nil)
        #expect(text == "已推送到 /sdcard/Download/a.jpg")
        #expect(actions.calls.contains("push a.jpg /sdcard/Download/a.jpg"))
        #expect(e.log.entries.map(\.title) == ["push_file a.jpg"])
        #expect(e.log.entries.first?.source == .ai)
    }

    @Test func pushFileToExplicitPath() async throws {
        let (e, actions) = env()
        let local = try file("a.jpg", in: try tempDir())
        let text = try await e.commands.pushFile(pixel, path: local.path, dest: "/sdcard/DCIM/b.jpg")
        #expect(text == "已推送到 /sdcard/DCIM/b.jpg")
        #expect(actions.calls.contains("push a.jpg /sdcard/DCIM/b.jpg"))
    }

    @Test func pushFileMissingLocal() async throws {
        let (e, actions) = env()
        let error = await asyncCode { _ = try await e.commands.pushFile(pixel, path: "/nonexistent/a.jpg", dest: nil) }
        #expect(error?.code == .INVALID_ARGUMENT)
        #expect(error?.message == "本机文件不存在：/nonexistent/a.jpg")
        let relative = await asyncCode { _ = try await e.commands.pushFile(pixel, path: "a.jpg", dest: nil) }
        #expect(relative?.code == .INVALID_ARGUMENT)
        #expect(!actions.calls.contains { $0.hasPrefix("push") })
    }

    @Test func pushFileRejectsBadDest() async throws {
        let (e, _) = env()
        let local = try file("a.jpg", in: try tempDir())
        let error = await asyncCode { _ = try await e.commands.pushFile(pixel, path: local.path, dest: "sdcard/x") }
        #expect(error?.code == .INVALID_ARGUMENT)
    }

    @Test func pushFileRejectedWhenLocked() async throws {
        let (e, actions) = env()
        let local = try file("a.jpg", in: try tempDir())
        e.locks.setLocked(pixel.id, true)
        let error = await asyncCode { _ = try await e.commands.pushFile(pixel, path: local.path, dest: nil) }
        #expect(error?.code == .AI_LOCKED)
        #expect(!actions.calls.contains { $0.hasPrefix("push") })
    }

    @Test func aiTransfersUseQueue() async throws {
        let (e, actions) = env()
        let gate = TransferGate()
        actions.transferGate = gate
        let local = try file("a.jpg", in: try tempDir())
        let task = Task { try await e.commands.pushFile(pixel, path: local.path, dest: nil) }
        var seen: TransferJob?
        for _ in 0..<400 where seen == nil {
            seen = e.transfers.jobs(pixel.id).first
            if seen == nil { try await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(seen?.source == .ai)
        gate.release()
        _ = try await task.value
    }

    @Test func installAppNeedsApk() async throws {
        let (e, actions) = env()
        let txt = try file("a.txt", in: try tempDir())
        let error = await asyncCode { _ = try await e.commands.installApp(pixel, path: txt.path) }
        #expect(error?.code == .INVALID_ARGUMENT)
        #expect(error?.message == "不是 APK 文件：\(txt.path)")
        #expect(!actions.calls.contains { $0.hasPrefix("install") })
    }

    @Test func installAppReportsPackage() async throws {
        let (e, actions) = env()
        let apk = try file("app-debug.APK", in: try tempDir())
        #expect(try await e.commands.installApp(pixel, path: apk.path) == "安装成功：com.demo")
        actions.installResult = nil
        #expect(try await e.commands.installApp(pixel, path: apk.path) == "安装成功")
        #expect(e.log.entries.last?.title == "install_app app-debug.APK")
    }

    // MARK: pull_file

    @Test func pullFilePullsIntoSubdirectory() async throws {
        let (e, actions) = env()
        let text = try await e.commands.pullFile(pixel, path: "/sdcard/x.log", dest: "sub/dir")
        let expected = e.pullDir.appendingPathComponent("sub/dir/x.log").path
        #expect(text == expected)
        #expect(FileManager.default.fileExists(atPath: expected))
        #expect(actions.calls.contains("pull /sdcard/x.log x.log"))
        #expect(e.log.entries.first?.title == "pull_file /sdcard/x.log")
    }

    @Test func pullFileEscapeIsRejected() async throws {
        let (e, actions) = env()
        let error = await asyncCode { _ = try await e.commands.pullFile(pixel, path: "/sdcard/x.log", dest: "../x") }
        #expect(error?.code == .INVALID_ARGUMENT)
        #expect(!actions.calls.contains { $0.hasPrefix("pull") })
    }

    @Test func pullDestinationCannotEscape() throws {
        let base = try tempDir()
        let outside = try tempDir()
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("link"), withDestinationURL: outside)
        // 指向 base 之外的符号链接（含其下的子目录）
        for bad in ["../x", "a/../../x", "/tmp", "link", "link/deeper"] {
            #expect(throws: DeviceError.self) { try AICommands.pullDestination(base: base, relative: bad) }
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("deeper").path))
        let ok = try AICommands.pullDestination(base: base, relative: "sub/dir")
        #expect(ok.path == base.appendingPathComponent("sub/dir").path)
        #expect(FileManager.default.fileExists(atPath: ok.path))
        #expect(try AICommands.pullDestination(base: base, relative: nil) == base)
        #expect(try AICommands.pullDestination(base: base, relative: "") == base)
    }

    @Test func pullDestinationIsComponentWise() throws {
        let parent = try tempDir()
        let base = parent.appendingPathComponent("Downloads")
        let sibling = parent.appendingPathComponent("Downloads2")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("s"), withDestinationURL: sibling)
        #expect(throws: DeviceError.self) { try AICommands.pullDestination(base: base, relative: "s") }
        // 指向 base 内部的符号链接允许
        try FileManager.default.createDirectory(at: base.appendingPathComponent("real"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: base.appendingPathComponent("inner"), withDestinationURL: base.appendingPathComponent("real"))
        _ = try AICommands.pullDestination(base: base, relative: "inner")
    }
}
