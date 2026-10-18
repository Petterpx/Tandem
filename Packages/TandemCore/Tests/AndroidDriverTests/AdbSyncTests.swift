import Foundation
import Testing
import DeviceCore
@testable import AndroidDriver

struct AdbSyncTests {
    // MARK: 构造应答

    private func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func u64(_ v: UInt64) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
    private func i64(_ v: Int64) -> Data { u64(UInt64(bitPattern: v)) }

    private func stat1(mode: UInt32, size: UInt32, mtime: UInt32) -> Data {
        Data("STAT".utf8) + u32(mode) + u32(size) + u32(mtime)
    }

    private func v2Body(error: UInt32 = 0, mode: UInt32, size: UInt64, mtime: Int64) -> Data {
        var d = Data()
        d.append(u32(error)); d.append(u64(0)); d.append(u64(0))
        d.append(u32(mode)); d.append(u32(1)); d.append(u32(0)); d.append(u32(0))
        d.append(u64(size)); d.append(i64(0)); d.append(i64(mtime)); d.append(i64(0))
        return d
    }

    private func stat2(error: UInt32 = 0, mode: UInt32, size: UInt64, mtime: Int64) -> Data {
        Data("STA2".utf8) + v2Body(error: error, mode: mode, size: size, mtime: mtime)
    }

    private func dent(_ name: String, mode: UInt32, size: UInt32 = 0, mtime: UInt32 = 0) -> Data {
        Data("DENT".utf8) + u32(mode) + u32(size) + u32(mtime) + u32(UInt32(name.utf8.count)) + Data(name.utf8)
    }

    private func dnt2(_ name: String, mode: UInt32, size: UInt64 = 0, mtime: Int64 = 0) -> Data {
        var d = Data("DNT2".utf8)
        d.append(v2Body(mode: mode, size: size, mtime: mtime))
        d.append(u32(UInt32(name.utf8.count)))
        d.append(Data(name.utf8))
        return d
    }

    /// DONE 与同版本的目录项等长（v1 为 16 字节，v2 为 72 字节）。
    private func done(v2: Bool = false) -> Data {
        Data("DONE".utf8) + Data(count: v2 ? 72 : 16)
    }

    /// 已通过 transport 与 sync: 握手的会话。
    private func session(_ reply: Data, features: Set<String> = []) async throws -> (AdbSyncSession, InMemoryByteStream) {
        let s = InMemoryByteStream(Data("OKAYOKAY".utf8) + reply)
        return (try await AdbSyncSession.open(s, serial: "S", features: features), s)
    }

    // MARK: host 请求

    @Test func requestHasHexLengthPrefix() async throws {
        let s = InMemoryByteStream(Data("OKAY".utf8))
        try await AdbHost.request(s, "host:transport:S")
        #expect(s.written == Data("0010host:transport:S".utf8))
    }

    @Test func transportFailCarriesReason() async throws {
        let s = InMemoryByteStream(Data("FAIL0014device 'S' not found".utf8))
        do {
            try await AdbHost.request(s, "host:transport:S")
            Issue.record("应抛错")
        } catch let e as DeviceError {
            #expect(e.code == .CONNECTION_FAILED)
            #expect(e.message.contains("device 'S' not found"))
        }
    }

    @Test func featuresParsed() async throws {
        let s = InMemoryByteStream(Data("OKAY001ashell_v2,stat_v2,ls_v2,cmd".utf8))
        let f = try await AdbHost.features(s, serial: "S")
        #expect(f.contains("ls_v2"))
        #expect(f.count == 4)
        #expect(s.written == Data("0016host-serial:S:features".utf8))
    }

    @Test func openSendsTransportThenSync() async throws {
        let (_, s) = try await session(Data())
        #expect(s.written == Data("0010host:transport:S0005sync:".utf8))
    }

    // MARK: STAT

    @Test func statV1() async throws {
        let (sync, s) = try await session(stat1(mode: 0o100644, size: 10, mtime: 1_700_000_000))
        let f = try #require(try await sync.stat("/sdcard/a.txt"))
        #expect(f.kind == .file)
        #expect(f.size == 10)
        #expect(f.modified == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(f.name == "a.txt")
        #expect(f.path == "/sdcard/a.txt")
        #expect(s.written.suffix(4 + 4 + 13) == Data("STAT".utf8) + u32(13) + Data("/sdcard/a.txt".utf8))
    }

    @Test func statV1ZeroModeIsNil() async throws {
        let (sync, _) = try await session(stat1(mode: 0, size: 0, mtime: 0))
        #expect(try await sync.stat("/nope") == nil)
    }

    @Test func stat2ReportsLargeSize() async throws {
        let (sync, s) = try await session(
            stat2(mode: 0o100644, size: 5_000_000_000, mtime: 1_700_000_000), features: ["stat_v2"])
        let f = try #require(try await sync.stat("/sdcard/big.bin"))
        #expect(f.size == 5_000_000_000)
        #expect(f.modified == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(s.written.suffix(4 + 4 + 15) == Data("STA2".utf8) + u32(15) + Data("/sdcard/big.bin".utf8))
    }

    @Test func stat2ErrorIsNil() async throws {
        let (sync, _) = try await session(stat2(error: 2, mode: 0, size: 0, mtime: 0), features: ["stat_v2"])
        #expect(try await sync.stat("/nope") == nil)
    }

    // MARK: LIST

    @Test func listV1SkipsDots() async throws {
        let reply = dent(".", mode: 0o040755) + dent("..", mode: 0o040755)
            + dent("a.txt", mode: 0o100644, size: 3, mtime: 100) + dent("DCIM", mode: 0o040770) + done()
        let (sync, s) = try await session(reply)
        let files = try await sync.list("/sdcard/")
        #expect(files.map(\.name) == ["a.txt", "DCIM"])
        #expect(files.map(\.kind) == [.file, .directory])
        #expect(files[0].path == "/sdcard/a.txt")
        #expect(files[0].size == 3)
        #expect(s.written.contains(Data("LIST".utf8)))
    }

    @Test func list2Parsed() async throws {
        let reply = dnt2(".", mode: 0o040755) + dnt2("..", mode: 0o040755)
            + dnt2("a.txt", mode: 0o100644, size: 5_000_000_000, mtime: 100)
            + dnt2("DCIM", mode: 0o040770) + dnt2("link", mode: 0o120777) + done(v2: true)
        let (sync, s) = try await session(reply, features: ["ls_v2"])
        let files = try await sync.list("/sdcard")
        #expect(files.map(\.name) == ["a.txt", "DCIM", "link"])
        #expect(files.map(\.kind) == [.file, .directory, .symlink])
        #expect(files[0].size == 5_000_000_000)
        #expect(files[1].path == "/sdcard/DCIM")
        #expect(s.written.contains(Data("LIS2".utf8)))
    }

    @Test func quitSendsQuitAndCloses() async throws {
        let (sync, s) = try await session(Data())
        sync.quit()
        _ = await s.waitForWritten(atLeast: 29 + 8)
        #expect(s.written.suffix(8) == Data("QUIT".utf8) + u32(0))
        for _ in 0..<500 where !s.isClosed { try await Task.sleep(for: .milliseconds(2)) }
        #expect(s.isClosed)
    }

    // MARK: FAIL 应答

    @Test func statFailCarriesReason() async throws {
        let (sync, _) = try await session(Data("FAIL".utf8) + u32(6) + Data("denied".utf8))
        do {
            _ = try await sync.stat("/x")
            Issue.record("应抛错")
        } catch let e as DeviceError {
            #expect(e.code == .CONNECTION_FAILED)
            #expect(e.message.contains("denied"))
        }
    }

    @Test func listRejectsOversizedName() async throws {
        let reply = Data("DENT".utf8) + u32(0o100644) + u32(0) + u32(0) + u32(1_000_000)
        let (sync, _) = try await session(reply)
        await #expect(throws: DeviceError.self) { _ = try await sync.list("/x") }
    }

    // MARK: SEND

    private func data(_ n: Int) -> Data { Data((0..<n).map { UInt8($0 % 251) }) }

    private func chunker(_ payload: Data) -> (Int) throws -> Data? {
        var offset = 0
        return { size in
            guard offset < payload.count else { return nil }
            let end = min(offset + size, payload.count)
            defer { offset = end }
            return payload.subdata(in: offset..<end)
        }
    }

    private let handshake = Data("0010host:transport:S0005sync:".utf8)

    @Test func sendChunksAt64K() async throws {
        let (sync, s) = try await session(Data("OKAY".utf8) + u32(0))
        let payload = data(150_000)
        nonisolated(unsafe) var seen: [UInt64] = []
        try await sync.send("/sdcard/a.bin", mode: 0o100644, mtime: Date(timeIntervalSince1970: 1_700_000_000),
                            read: chunker(payload), progress: { seen.append($0) })
        let req = "/sdcard/a.bin,33188"
        var expected = Data("SEND".utf8) + u32(UInt32(req.utf8.count)) + Data(req.utf8)
        expected += Data("DATA".utf8) + u32(65536) + payload[0..<65536]
        expected += Data("DATA".utf8) + u32(65536) + payload[65536..<131072]
        expected += Data("DATA".utf8) + u32(18928) + payload[131072...]
        expected += Data("DONE".utf8) + u32(1_700_000_000)
        #expect(s.written == handshake + expected)
        #expect(seen == [65536, 131072, 150_000])
    }

    @Test func zeroByteFileSendsOnlyDone() async throws {
        let (sync, s) = try await session(Data("OKAY".utf8) + u32(0))
        try await sync.send("/a", mode: 0o100644, mtime: Date(timeIntervalSince1970: 5),
                            read: { _ in nil }, progress: { _ in })
        let req = "/a,33188"
        #expect(s.written == handshake + Data("SEND".utf8) + u32(UInt32(req.utf8.count)) + Data(req.utf8)
                + Data("DONE".utf8) + u32(5))
    }

    @Test func sendFailCarriesReason() async throws {
        let (sync, _) = try await session(Data("FAIL".utf8) + u32(17) + Data("Permission denied".utf8))
        do {
            try await sync.send("/a", mode: 0o100644, mtime: Date(), read: { _ in nil }, progress: { _ in })
            Issue.record("应抛错")
        } catch let e as DeviceError {
            #expect(e.code == .CONNECTION_FAILED)
            #expect(e.message == "推送失败：Permission denied")
        }
    }

    // MARK: RECV

    @Test func recvConcatenatesChunks() async throws {
        let reply = Data("DATA".utf8) + u32(3) + Data("abc".utf8) + Data("DATA".utf8) + u32(2) + Data("de".utf8)
            + Data("DONE".utf8) + u32(0)
        let (sync, s) = try await session(reply)
        nonisolated(unsafe) var got = Data()
        nonisolated(unsafe) var seen: [UInt64] = []
        try await sync.recv("/sdcard/x", write: { got.append($0) }, progress: { seen.append($0) })
        #expect(got == Data("abcde".utf8))
        #expect(seen == [3, 5])
        #expect(s.written == handshake + Data("RECV".utf8) + u32(9) + Data("/sdcard/x".utf8))
    }

    @Test func recvFail() async throws {
        let msg = "No such file or directory"
        let (sync, _) = try await session(Data("FAIL".utf8) + u32(UInt32(msg.utf8.count)) + Data(msg.utf8))
        do {
            try await sync.recv("/nope", write: { _ in }, progress: { _ in })
            Issue.record("应抛错")
        } catch let e as DeviceError {
            #expect(e.message == "拉取失败：" + msg)
        }
    }

    @Test func recvRejectsOversizedChunk() async throws {
        let (sync, _) = try await session(Data("DATA".utf8) + u32(70_000))
        await #expect(throws: DeviceError.self) {
            try await sync.recv("/x", write: { _ in }, progress: { _ in })
        }
    }

    @Test func eofMidTransferFails() async throws {
        let (sync, s) = try await session(Data("DATA".utf8) + u32(10) + Data("abc".utf8))
        s.finish()
        do {
            try await sync.recv("/x", write: { _ in }, progress: { _ in })
            Issue.record("应抛错")
        } catch let e as DeviceError {
            #expect(e.code == .CONNECTION_FAILED)
            #expect(e.message == "连接中断")
        }
    }

    @Test func cancelClosesConnection() async throws {
        let (sync, s) = try await session(Data())
        s.writeDelay = { .milliseconds(5) }
        let task = Task {
            try await sync.send("/a", mode: 0o100644, mtime: Date(),
                                read: { _ in Data(count: 1024) }, progress: { _ in })
        }
        _ = await s.waitForWritten(atLeast: handshake.count + 100)
        task.cancel()
        do {
            try await task.value
            Issue.record("应抛 CancellationError")
        } catch is CancellationError {
        }
        #expect(s.isClosed)
    }

    @Test func recvCancelClosesConnection() async throws {
        let (sync, s) = try await session(Data("DATA".utf8) + u32(3) + Data("abc".utf8))
        // 先收到一块，然后流上没有更多数据，读被挂起；取消后应关闭并抛 CancellationError。
        let task = Task {
            try await sync.recv("/x", write: { _ in }, progress: { _ in })
        }
        _ = await s.waitForWritten(atLeast: handshake.count + 12)
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()
        do {
            try await task.value
            Issue.record("应抛 CancellationError")
        } catch is CancellationError {
        }
        #expect(s.isClosed)
    }
}
