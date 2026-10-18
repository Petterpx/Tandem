import Foundation
import Testing
import DeviceCore
@testable import AndroidDriver

private let adbPath = "/fake/adb"

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-files-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct AndroidFilesTests {
    @Test func endpointFromEnvironment() {
        #expect(AdbServerEndpoint.port(environment: ["ADB_SERVER_SOCKET": "tcp:5038"]) == 5038)
        #expect(AdbServerEndpoint.port(environment: ["ADB_SERVER_SOCKET": "tcp:localhost:5039"]) == 5039)
        #expect(AdbServerEndpoint.port(environment: [:]) == 5037)
    }

    @Test func startServerRetriedOnce() async throws {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, ["start-server"])
        let factory = StreamFactory(streams(Data("DONE".utf8) + Data(count: 16)), failures: 1)
        let list = try await makeActions(runner, factory).listDirectory("/sdcard")
        #expect(list.isEmpty)
        #expect(runner.calls.filter { $0.args == ["start-server"] }.count == 1)
    }

    @Test func connectFailureTwiceReportsCannotConnect() async {
        let runner = FakeProcessRunner()
        runner.stub(adbPath, ["start-server"])
        let factory = StreamFactory([], failures: 2)
        do {
            _ = try await makeActions(runner, factory).listDirectory("/sdcard")
            Issue.record("应抛错")
        } catch let e as DeviceError {
            #expect(e.code == .CONNECTION_FAILED)
            #expect(e.message == "无法连接 adb 服务")
        } catch { Issue.record("错误类型不对：\(error)") }
    }

    @Test func featuresCachedPerInstance() async throws {
        let runner = FakeProcessRunner()
        let done = Data("DONE".utf8) + Data(count: 16)
        let factory = StreamFactory([
            InMemoryByteStream(featuresReply),
            InMemoryByteStream(Data("OKAYOKAY".utf8) + done),
            InMemoryByteStream(Data("OKAYOKAY".utf8) + done),
        ])
        let actions = makeActions(runner, factory)
        _ = try await actions.listDirectory("/sdcard")
        _ = try await actions.listDirectory("/sdcard")
        #expect(factory.calls == 3)
    }

    @Test func invalidPathRejectedBeforeConnecting() async {
        let factory = StreamFactory([])
        do {
            _ = try await makeActions(FakeProcessRunner(), factory).stat("relative")
            Issue.record("应抛错")
        } catch let e as DeviceError {
            #expect(e.code == .INVALID_ARGUMENT)
        } catch { Issue.record("错误类型不对：\(error)") }
        #expect(factory.calls == 0)
    }

    @Test func pushFolderRecurses() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("f")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try Data("aa".utf8).write(to: root.appendingPathComponent("a.txt"))
        try Data("bbb".utf8).write(to: root.appendingPathComponent("sub/b.txt"))

        let ok = Data("OKAY".utf8) + u32(0)
        let factory = StreamFactory(streams(ok + ok))
        nonisolated(unsafe) var seen: [TransferProgress] = []
        try await makeActions(FakeProcessRunner(), factory)
            .push(root, to: "/sdcard/Download/f", progress: { seen.append($0) })

        let written = String(decoding: factory.made[1].written, as: UTF8.self)
        let a = try #require(written.range(of: "/sdcard/Download/f/a.txt,"))
        let b = try #require(written.range(of: "/sdcard/Download/f/sub/b.txt,"))
        #expect(a.lowerBound < b.lowerBound)
        #expect(seen.last == TransferProgress(bytes: 5, total: 5))
        #expect(seen.allSatisfy { $0.total == 5 })
    }

    @Test func emptyFolderIsCreated() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("f")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("e"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("a.txt"))

        let runner = FakeProcessRunner()
        runner.stub(adbPath, ["-s", "S", "shell", "mkdir -p '/sdcard/Download/f/e'"])
        let factory = StreamFactory(streams(Data("OKAY".utf8) + u32(0)))
        try await makeActions(runner, factory).push(root, to: "/sdcard/Download/f", progress: { _ in })
        #expect(runner.calls.map(\.args).contains(["-s", "S", "shell", "mkdir -p '/sdcard/Download/f/e'"]))
    }

    @Test func cancelRemovesRemotePartial() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.bin")
        try Data(count: 10).write(to: file)

        let runner = FakeProcessRunner()
        let rm = ["-s", "S", "shell", "rm -f '/sdcard/a.bin'"]
        runner.stub(adbPath, rm)
        // 没有 OKAY 应答：DONE 写出后会一直等读。
        let factory = StreamFactory(streams(Data()))
        let actions = makeActions(runner, factory)
        let task = Task { try await actions.push(file, to: "/sdcard/a.bin", progress: { _ in }) }
        _ = await waitFor { factory.made.count == 2 }
        _ = await factory.made[1].waitForWritten(atLeast: 40)
        task.cancel()
        do {
            try await task.value
            Issue.record("应被取消")
        } catch is CancellationError {
        } catch { Issue.record("错误类型不对：\(error)") }
        #expect(runner.calls.map(\.args).contains(rm))
    }

    @Test func shellPathsAreQuoted() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.bin")
        try Data(count: 3).write(to: file)

        let evil = "/sdcard/x'; reboot; echo '.jpg"
        let runner = FakeProcessRunner()
        let rm = ["-s", "S", "shell", "rm -f '/sdcard/x'\\''; reboot; echo '\\''.jpg'"]
        runner.stub(adbPath, rm)
        let factory = StreamFactory(streams(Data("FAIL".utf8) + u32(6) + Data("denied".utf8)))
        do {
            try await makeActions(runner, factory).push(file, to: evil, progress: { _ in })
            Issue.record("应抛错")
        } catch let e as DeviceError {
            #expect(e.message == "推送失败：denied")
        } catch { Issue.record("错误类型不对：\(error)") }
        #expect(runner.calls.map(\.args).contains(rm))
        #expect(factory.made[1].written.range(of: Data(evil.utf8)) != nil)
        #expect(factory.made[1].isClosed)
    }

    private func stat1(size: UInt32) -> Data { Data("STAT".utf8) + u32(0o100644) + u32(size) + u32(0) }

    @Test func pullWritesPartThenRenames() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("out.bin")
        try Data("old".utf8).write(to: dest)

        let body = stat1(size: 5) + Data("DATA".utf8) + u32(5) + Data("hello".utf8) + Data("DONE".utf8) + u32(0)
        let factory = StreamFactory(streams(body))
        nonisolated(unsafe) var seen: [TransferProgress] = []
        try await makeActions(FakeProcessRunner(), factory).pull("/sdcard/a.bin", to: dest, progress: { seen.append($0) })

        #expect(try Data(contentsOf: dest) == Data("hello".utf8))
        #expect(!FileManager.default.fileExists(atPath: dest.path + ".part"))
        #expect(seen.last == TransferProgress(bytes: 5, total: 5))
    }

    @Test func pullFailureLeavesNothing() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let dest = dir.appendingPathComponent("out.bin")

        let body = stat1(size: 5) + Data("DATA".utf8) + u32(2) + Data("he".utf8) + Data("FAIL".utf8) + u32(4) + Data("boom".utf8)
        let factory = StreamFactory(streams(body))
        do {
            try await makeActions(FakeProcessRunner(), factory).pull("/sdcard/a.bin", to: dest, progress: { _ in })
            Issue.record("应抛错")
        } catch let e as DeviceError {
            #expect(e.message == "拉取失败：boom")
        } catch { Issue.record("错误类型不对：\(error)") }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
        #expect(!FileManager.default.fileExists(atPath: dest.path + ".part"))
    }

    private func waitFor(_ condition: @Sendable () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return condition()
    }
}
