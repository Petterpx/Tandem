import Foundation
import os

public enum SocketError: Error, Equatable, LocalizedError {
    case pathTooLong(String)
    /// 路径上已有 socket 在监听（另一个 Tandem 在运行）。
    case alreadyInUse
    case closed
    /// 系统调用失败：操作名 + errno。
    case system(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let path): "socket 路径过长：\(path)"
        case .alreadyInUse: "已有 Tandem 在运行"
        case .closed: "连接已关闭"
        case .system(let op, let code): "\(op)失败（\(code)）"
        }
    }
}

/// sun_path 的容量（含结尾 0），macOS 上是 104 字节。
private let sunPathCapacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)

/// 新建 AF_UNIX 流 socket 并设 SO_NOSIGPIPE（对端关闭后写入返回 EPIPE，而不是用 SIGPIPE 杀进程）。
private func makeSocket() throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw SocketError.system("socket", errno) }
    do {
        try setNoSigPipe(fd)
    } catch {
        Darwin.close(fd)
        throw error
    }
    return fd
}

private func setNoSigPipe(_ fd: Int32) throws {
    var on: Int32 = 1
    guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
        throw SocketError.system("setsockopt", errno)
    }
}

/// 对 sockaddr_un 形式的地址执行 bind / connect。调用方已检查过路径长度。
private func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        path.utf8CString.withUnsafeBytes { buf.copyMemory(from: $0) }
    }
    return withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

private func checkLength(_ path: String) throws {
    if path.utf8.count >= sunPathCapacity { throw SocketError.pathTooLong(path) }
}

/// 一条 Unix socket 连接：专用线程阻塞读，按行放进 `incoming`。
public final class UnixSocketConnection: LineChannel {
    public let incoming: AsyncStream<Data>
    private let fd: Int32
    private let closed = OSAllocatedUnfairLock(initialState: false)
    /// 串行化 send，保证并发调用时每行完整写出。
    private let writeLock = NSLock()
    /// 读线程退出时 signal；close() 等它退出后才关闭 fd，避免读线程用到被复用的 fd。
    private let readerExited = DispatchSemaphore(value: 0)

    init(fd: Int32) {
        self.fd = fd
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        incoming = stream
        let thread = Thread { [self] in readLoop(continuation) }
        thread.name = "dev.tandem.socket.read"
        thread.start()
    }

    /// 读线程持有 self，所以走到这里时读线程已退出：没调用过 close() 就在这里关闭 fd。
    deinit {
        if !closed.withLock({ $0 }) { Darwin.close(fd) }
    }

    public static func connect(path: String) throws -> UnixSocketConnection {
        try checkLength(path)
        let fd = try makeSocket()
        guard withAddress(path, { Darwin.connect(fd, $0, $1) }) == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketError.system("connect", code)
        }
        return UnixSocketConnection(fd: fd)
    }

    private func readLoop(_ continuation: AsyncStream<Data>.Continuation) {
        var reader = LineReader()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                for line in reader.append(Data(buffer[0..<n])) { continuation.yield(line) }
            } else if n < 0 && errno == EINTR {
                continue
            } else {
                break   // 0 = 对端关闭；其他错误同样结束
            }
        }
        continuation.finish()
        readerExited.signal()
    }

    public func send(_ line: Data) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed.withLock({ $0 }) else { throw SocketError.closed }
        var bytes = line
        bytes.append(0x0A)
        try bytes.withUnsafeBytes { buf in
            var offset = 0
            while offset < buf.count {
                let n = write(fd, buf.baseAddress! + offset, buf.count - offset)
                if n >= 0 {
                    offset += n
                } else if errno != EINTR {
                    throw SocketError.system("write", errno)
                }
            }
        }
    }

    /// 可重复调用。shutdown 唤醒阻塞中的 read / write，等读线程与进行中的 send 结束后关闭 fd；
    /// 返回时对端已能看到连接断开。
    public func close() {
        let first = closed.withLock { c in
            defer { c = true }
            return !c
        }
        guard first else { return }
        shutdown(fd, SHUT_RDWR)
        readerExited.wait()
        // 之后的 send 都会看到 closed。
        writeLock.lock()
        Darwin.close(fd)
        writeLock.unlock()
    }
}

/// 监听 Unix socket：专用线程阻塞 accept，新连接放进 `connections`。
public final class UnixSocketListener: Sendable {
    public let connections: AsyncStream<UnixSocketConnection>
    private let path: String
    private let fd: Int32
    /// 唤醒管道：macOS 上对监听 socket 调 shutdown 无效（ENOTCONN），跨线程 close fd 又可能撞上 fd 复用，
    /// 所以 accept 线程用 poll 同时等它，close() 往里写一个字节让线程自己退出并关闭 fd。
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let closed = OSAllocatedUnfairLock(initialState: false)

    public init(path: String) throws {
        try checkLength(path)
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            let ns = error as NSError
            let code = (ns.userInfo[NSUnderlyingErrorKey] as? NSError)?.code ?? ns.code
            throw SocketError.system("创建目录", Int32(code))
        }
        if FileManager.default.fileExists(atPath: path) {
            // 连得上说明另一个 Tandem 正在监听，不能抢；连不上就是崩溃残留，删掉重建。
            if let probe = try? UnixSocketConnection.connect(path: path) {
                probe.close()
                throw SocketError.alreadyInUse
            }
            unlink(path)
        }
        let fd = try makeSocket()
        var pipeFDs: [Int32] = [0, 0]
        var bound = false
        do {
            guard withAddress(path, { bind(fd, $0, $1) }) == 0 else {
                // 探测之后、bind 之前被别的进程抢先监听
                throw errno == EADDRINUSE ? SocketError.alreadyInUse : SocketError.system("bind", errno)
            }
            bound = true
            guard chmod(path, 0o600) == 0 else { throw SocketError.system("chmod", errno) }
            guard listen(fd, 16) == 0 else { throw SocketError.system("listen", errno) }
            guard pipe(&pipeFDs) == 0 else { throw SocketError.system("pipe", errno) }
        } catch {
            Darwin.close(fd)
            if bound { unlink(path) }   // 只删自己创建的文件
            throw error
        }
        self.path = path
        self.fd = fd
        wakeRead = pipeFDs[0]
        wakeWrite = pipeFDs[1]
        let (stream, continuation) = AsyncStream<UnixSocketConnection>.makeStream()
        connections = stream
        let thread = Thread { [fd, wakeRead, wakeWrite] in
            Self.acceptLoop(fd: fd, wake: wakeRead, continuation)
            // 因 accept 出错提前退出时也要等到 close()，否则 close() 写唤醒字节时 fd 可能已被复用。
            var byte: UInt8 = 0
            while read(wakeRead, &byte, 1) < 0 && errno == EINTR {}
            Darwin.close(fd)
            Darwin.close(wakeRead)
            Darwin.close(wakeWrite)
        }
        thread.name = "dev.tandem.socket.accept"
        thread.start()
    }

    private static func acceptLoop(
        fd: Int32, wake: Int32, _ continuation: AsyncStream<UnixSocketConnection>.Continuation
    ) {
        defer { continuation.finish() }
        var fds = [pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
                   pollfd(fd: wake, events: Int16(POLLIN), revents: 0)]
        while true {
            if poll(&fds, 2, -1) < 0 {
                if errno == EINTR { continue }
                return
            }
            if fds[1].revents != 0 { return }   // close() 唤醒
            guard fds[0].revents != 0 else { continue }
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return
            }
            guard (try? setNoSigPipe(client)) != nil else {
                Darwin.close(client)
                continue
            }
            continuation.yield(UnixSocketConnection(fd: client))
        }
    }

    deinit { close() }

    /// 停止监听并删除 socket 文件；可重复调用。已接受的连接不受影响。
    public func close() {
        let first = closed.withLock { c in
            defer { c = true }
            return !c
        }
        guard first else { return }
        unlink(path)
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)
    }
}
