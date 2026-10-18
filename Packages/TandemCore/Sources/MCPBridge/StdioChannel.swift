import Foundation
import os
import ControlProtocol

/// stdin / stdout 上的按行通道（MCP stdio 传输）：专用线程阻塞读 stdin，写 stdout 时加锁保证整行输出。
/// 调用方应忽略 SIGPIPE，客户端关闭 stdout 后写入才会抛错而不是杀掉进程。
public final class StdioChannel: LineChannel {
    public let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let closed = OSAllocatedUnfairLock(initialState: false)
    private let writeLock = NSLock()

    public init() {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        incoming = stream
        self.continuation = continuation
        let thread = Thread {
            var reader = LineReader()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if n > 0 {
                    for line in reader.append(Data(buffer[0..<n])) { continuation.yield(line) }
                } else if n < 0 && errno == EINTR {
                    continue
                } else {
                    break   // 0 = stdin 结束；其他错误同样结束
                }
            }
            continuation.finish()
        }
        thread.name = "dev.tandem.stdio.read"
        thread.start()
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
                let n = write(STDOUT_FILENO, buf.baseAddress! + offset, buf.count - offset)
                if n >= 0 {
                    offset += n
                } else if errno != EINTR {
                    throw SocketError.system("write", errno)
                }
            }
        }
    }

    /// 结束 incoming，之后的 send 抛错。读线程仍阻塞在 stdin 上，随进程退出。
    public func close() {
        closed.withLock { $0 = true }
        continuation.finish()
    }
}
