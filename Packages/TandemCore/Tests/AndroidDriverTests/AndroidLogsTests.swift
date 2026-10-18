import Foundation
import Testing
import DeviceCore
@testable import AndroidDriver

private let adbPath = "/fake/adb"
private let snapArgs = ["-s", "S", "shell", AndroidCommands.Logs.snapshotCommand(minLevel: .verbose)]
private let pidofArgs = ["-s", "S", "shell", "pidof 'com.demo'"]
private let streamArgs = ["-s", "S", "logcat", "-v", "threadtime", "-T", "1"]

private func line(_ pid: Int, _ tag: String, _ msg: String, _ time: String = "10-18 10:00:00.000") -> String {
    "\(time)  \(pid)  \(pid) I \(tag): \(msg)"
}

private func actions(_ runner: FakeProcessRunner) -> AndroidActions { makeActions(runner, StreamFactory([])) }

@Suite struct AndroidLogActionsTests {
    @Test func snapshotFiltersByPids() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, pidofArgs, stdout: "123\n")
        runner.stub(adbPath, snapArgs, stdout: [
            line(99, "ActivityManager", "Start proc 99:com.demo/u0a1 for activity"),
            line(123, "A", "one"), line(7, "B", "other"), line(99, "C", "two"),
        ].joined(separator: "\n") + "\n")
        let s = try await actions(runner).logSnapshot(LogQuery(package: "com.demo"))
        #expect(s.pids == [123, 99])
        #expect(s.entries.map(\.pid) == [99, 123, 99])
        #expect(s.note == nil)
        #expect(runner.timeout(adbPath, snapArgs) == .seconds(20))
    }

    @Test func snapshotEmptyHasNote() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, pidofArgs, exitCode: 1)
        runner.stub(adbPath, snapArgs, stdout: line(7, "B", "other") + "\n")
        let s = try await actions(runner).logSnapshot(LogQuery(package: "com.demo"))
        #expect(s == LogSnapshot(entries: [], pids: [], note: "缓冲中没有 com.demo 的记录"))
    }

    @Test func pidofSeveralPidsAndInvalidPackage() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, pidofArgs, stdout: "12 34 \n")
        #expect(try await actions(runner).pids(of: "com.demo") == [12, 34])
        await #expect(throws: DeviceError.self) { _ = try await actions(runner).pids(of: "com.demo; reboot") }
    }

    @Test func grepIsCaseInsensitive() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, snapArgs, stdout: [line(1, "Net", "hello"), line(1, "X", "HeLLo world"), line(1, "HELLOtag", "z"), line(1, "Y", "no")].joined(separator: "\n"))
        let s = try await actions(runner).logSnapshot(LogQuery(grep: "hello"))
        #expect(s.entries.map(\.tag) == ["Net", "X", "HELLOtag"])
    }

    @Test func linesTakesLast() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, snapArgs, stdout: (1...5).map { line($0, "T", "m\($0)") }.joined(separator: "\n"))
        let s = try await actions(runner).logSnapshot(LogQuery(lines: 2))
        #expect(s.entries.map(\.pid) == [4, 5])
    }

    @Test func allWhenPackageNil() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, snapArgs, stdout: line(1, "T", "m") + "\n")
        let s = try await actions(runner).logSnapshot(LogQuery())
        #expect(s.entries.count == 1 && s.pids.isEmpty)
        #expect(!runner.calls.contains { $0.args.last?.hasPrefix("pidof") == true })
    }

    @Test func snapshotWithNotFoundTextStillParses() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, snapArgs, stdout: line(1, "T", "file not found: Unknown command") + "\n")
        let s = try await actions(runner).logSnapshot(LogQuery())
        #expect(s.entries.map(\.message) == ["file not found: Unknown command"])
    }

    @Test func streamParsesAndTerminates() async throws {
        let runner = FakeProcessRunner()
        runner.stubStream(adbPath, streamArgs, lines: [
            "--------- beginning of main", line(1, "A", "a"), line(2, "B", "b"), line(3, "C", "c"),
        ])
        let stream = try actions(runner).logStream()
        var got: [LogEntry] = []
        for try await e in stream { got.append(e) }
        #expect(got.map(\.tag) == ["A", "B", "C"])
    }

    @Test func streamCancellationTerminatesProcess() async throws {
        let process = LiveFakeProcess()
        let runner = LiveFakeRunner(process)
        let a = AndroidActions(serial: "S", adb: AdbClient(adb: Adb(url: URL(fileURLWithPath: adbPath), version: "1"), runner: runner))
        let stream = try a.logStream()
        let task = Task { for try await _ in stream {} }
        process.emit(line(1, "A", "a"))
        task.cancel()
        _ = try? await task.value
        for _ in 0..<50 where !process.terminated { try await Task.sleep(for: .milliseconds(20)) }
        #expect(process.terminated)
    }
}

/// 不自行结束的进程，用于验证取消时的 terminate。
private final class LiveFakeProcess: RunningProcess, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let cont: AsyncStream<String>.Continuation
    private let lock = NSLock()
    private var _terminated = false
    var terminated: Bool { lock.withLock { _terminated } }
    init() { (lines, cont) = AsyncStream<String>.makeStream() }
    func emit(_ s: String) { cont.yield(s) }
    func terminate() { lock.withLock { _terminated = true }; cont.finish() }
}

private struct LiveFakeRunner: ProcessRunner {
    let process: LiveFakeProcess
    init(_ p: LiveFakeProcess) { process = p }
    func run(_ executable: URL, _ args: [String], timeout: Duration) async throws -> ProcessResult { fatalError() }
    func stream(_ executable: URL, _ args: [String]) throws -> RunningProcess { process }
    func streamBytes(_ executable: URL, _ args: [String]) throws -> (bytes: AsyncStream<Data>, process: RunningProcess) { fatalError() }
}
