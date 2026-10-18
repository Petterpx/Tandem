import Testing
import Foundation
@testable import ControlProtocol

/// sun_path 只有 104 字节，测试 socket 放在 /tmp 下用短名。
private func tmpSocket() -> String {
    "/tmp/tdm-\(UUID().uuidString.prefix(8)).sock"
}

/// 取流的第一个元素；流结束时返回 nil。
private func first(_ stream: AsyncStream<Data>) async -> Data? {
    var it = stream.makeAsyncIterator()
    return await it.next()
}

private func permissions(_ path: String) throws -> Int {
    let attrs = try FileManager.default.attributesOfItem(atPath: path)
    return try #require(attrs[.posixPermissions] as? Int)
}

/// 直接 bind 后 close fd、不 unlink，模拟 App 崩溃后残留的 socket 文件。
private func leaveStaleSocket(at path: String) {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        path.utf8CString.withUnsafeBytes { buf.copyMemory(from: $0) }
    }
    _ = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    close(fd)
}

@Test func linesRoundTripBothWays() async throws {
    let path = tmpSocket()
    let l = try UnixSocketListener(path: path)
    defer { l.close() }
    let c = try UnixSocketConnection.connect(path: path)
    defer { c.close() }
    var it = l.connections.makeAsyncIterator()
    let s = try #require(await it.next())
    defer { s.close() }
    try c.send(Data("你好".utf8))
    try s.send(Data("ok".utf8))
    #expect(await first(s.incoming) == Data("你好".utf8))
    #expect(await first(c.incoming) == Data("ok".utf8))
}

@Test func socketFileIsOwnerOnly() throws {
    let dir = "/tmp/tdm-\(UUID().uuidString.prefix(8))"
    let path = dir + "/c.sock"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let l = try UnixSocketListener(path: path)
    defer { l.close() }
    #expect(try permissions(path) == 0o600)
    #expect(try permissions(dir) == 0o700)
}

@Test func existingDirectoryIsMadeOwnerOnly() throws {
    let dir = "/tmp/tdm-\(UUID().uuidString.prefix(8))"
    let path = dir + "/c.sock"
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o755])
    let l = try UnixSocketListener(path: path)
    defer { l.close() }
    #expect(try permissions(dir) == 0o700)
}

@Test func staleSocketIsReplaced() throws {
    let path = tmpSocket()
    leaveStaleSocket(at: path)
    #expect(FileManager.default.fileExists(atPath: path))
    let l = try UnixSocketListener(path: path)
    defer { l.close() }
    let c = try UnixSocketConnection.connect(path: path)
    c.close()
}

@Test func liveSocketIsNotStolen() async throws {
    let path = tmpSocket()
    let l = try UnixSocketListener(path: path)
    defer { l.close() }
    #expect(throws: SocketError.alreadyInUse) { try UnixSocketListener(path: path) }
    let c = try UnixSocketConnection.connect(path: path)
    defer { c.close() }
    try c.send(Data("still here".utf8))
    // 第二个 listener 的探测连接可能先被接受（随即结束），也可能已被系统丢弃；跳过它找到 c。
    var received: Data?
    for await s in l.connections {
        received = await first(s.incoming)
        s.close()
        if received != nil { break }
    }
    #expect(received == Data("still here".utf8))
}

@Test func overlongPathIsRejected() {
    let path = "/tmp/" + String(repeating: "a", count: 115)
    #expect(path.utf8.count == 120)
    #expect(throws: SocketError.pathTooLong(path)) { try UnixSocketListener(path: path) }
    #expect(throws: SocketError.pathTooLong(path)) { try UnixSocketConnection.connect(path: path) }
}

@Test func peerCloseFinishesIncoming() async throws {
    let path = tmpSocket()
    let l = try UnixSocketListener(path: path)
    defer { l.close() }
    let c = try UnixSocketConnection.connect(path: path)
    var it = l.connections.makeAsyncIterator()
    let s = try #require(await it.next())
    defer { s.close() }
    c.close()
    c.close()   // 可重复调用
    #expect(await first(s.incoming) == nil)
    #expect(await first(c.incoming) == nil)
    #expect(throws: SocketError.closed) { try c.send(Data("x".utf8)) }
}

@Test func sendAfterPeerClosedThrows() async throws {
    let path = tmpSocket()
    let l = try UnixSocketListener(path: path)
    defer { l.close() }
    let c = try UnixSocketConnection.connect(path: path)
    defer { c.close() }
    var it = l.connections.makeAsyncIterator()
    let s = try #require(await it.next())
    s.close()
    #expect(await first(c.incoming) == nil)
    // 对端 fd 已关闭，写入应很快以 EPIPE 失败；给足时间以免偶发抖动
    let error = await #expect(throws: SocketError.self) {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            try c.send(Data(repeating: 0x61, count: 1024))
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    switch error {
    case .closed?, .system?: break
    default: Issue.record("意外的错误 \(String(describing: error))")
    }
}

@Test func connectWithoutListenerThrows() {
    let path = tmpSocket()
    let error = #expect(throws: SocketError.self) { try UnixSocketConnection.connect(path: path) }
    guard case .some(.system(let op, _)) = error else {
        Issue.record("应为 system 错误：\(String(describing: error))")
        return
    }
    #expect(op == "connect")
}

@Test func closeRemovesSocketFile() throws {
    let path = tmpSocket()
    let l = try UnixSocketListener(path: path)
    #expect(FileManager.default.fileExists(atPath: path))
    l.close()
    #expect(!FileManager.default.fileExists(atPath: path))
    l.close()   // 可重复调用
}

@Test func socketErrorDescriptions() {
    #expect(SocketError.alreadyInUse.errorDescription == "已有 Tandem 在运行")
    #expect(SocketError.closed.errorDescription == "连接已关闭")
    #expect(SocketError.system("connect", 2).errorDescription == "connect失败（2）")
    #expect(SocketError.pathTooLong("/x").errorDescription?.contains("路径过长") == true)
}
