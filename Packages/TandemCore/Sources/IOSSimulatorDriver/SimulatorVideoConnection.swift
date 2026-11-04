import Darwin
import DeviceCore
import Foundation
import MediaKit

/// A per-helper Unix socket owned by this generation, never a listening TCP service.
/// One reader decodes packets in order, waiting for VT output before reading again.
/// Only decoded frames can coalesce, with one latest frame retained for the session.
final class SimulatorVideoConnection: @unchecked Sendable {
    let path: String
    let frames: AsyncThrowingStream<VideoFrame, Error>
    private let continuation: AsyncThrowingStream<VideoFrame, Error>.Continuation
    private let directory: String
    private let listener: Int32
    private let lock = NSLock()
    private var client: Int32 = -1
    private var closed = false

    init() throws {
        (frames, continuation) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        var template = Array("/tmp/tandem-video.XXXXXX".utf8CString)
        guard let created = mkdtemp(&template) else { throw Self.failure("无法创建私有视频目录") }
        directory = String(cString: created)
        path = directory + "/video.sock"
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else {
            try? FileManager.default.removeItem(atPath: directory)
            throw Self.failure("无法创建视频通道")
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, listen(listener, 1) == 0 else {
            Darwin.close(listener)
            try? FileManager.default.removeItem(atPath: directory)
            throw Self.failure("无法监听私有视频通道")
        }
        _ = fcntl(listener, F_SETFL, fcntl(listener, F_GETFL) | O_NONBLOCK)
    }

    func start() {
        DispatchQueue(label: "dev.tandem.simulator.video.decode", qos: .userInteractive).async { [self] in readFrames() }
    }

    private func readFrames() {
        let decoder = H264Decoder { [continuation] in continuation.yield($0) }
        defer {
            decoder.reset()
            let descriptor = lock.withLock { let fd = client; client = -1; return fd }
            if descriptor >= 0 { Darwin.close(descriptor) }
            Darwin.close(listener)
            try? FileManager.default.removeItem(atPath: directory)
            continuation.finish()
        }
        do {
            var accepted: Int32 = -1
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while !lock.withLock({ closed }), ProcessInfo.processInfo.systemUptime < deadline {
                accepted = Darwin.accept(listener, nil, nil)
                if accepted >= 0 { break }
                guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else { throw Self.failure("视频连接失败") }
                var descriptor = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
                _ = poll(&descriptor, 1, 25)
            }
            guard accepted >= 0 else {
                if lock.withLock({ closed }) { return }
                throw Self.failure("等待视频连接超时")
            }
            let shouldRead = lock.withLock {
                guard !closed else { return false }
                client = accepted
                return true
            }
            guard shouldRead else { Darwin.close(accepted); return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(accepted, &uid, &gid) == 0, uid == geteuid() else { throw Self.failure("视频连接用户无效") }
            _ = fcntl(accepted, F_SETFL, fcntl(accepted, F_GETFL) | O_NONBLOCK)
            var size: Int32 = 64 * 1024
            _ = setsockopt(accepted, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout.size(ofValue: size)))
            var framer = SimulatorVideoPacketDecoder()
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while !lock.withLock({ closed }) {
                let count = Darwin.read(accepted, &buffer, buffer.count)
                if count == 0 { try framer.finish(); break }
                if count < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK {
                        var descriptor = pollfd(fd: accepted, events: Int16(POLLIN), revents: 0)
                        _ = poll(&descriptor, 1, 25)
                        continue
                    }
                    throw Self.failure("视频通道已关闭")
                }
                for packet in try framer.append(Data(buffer.prefix(count))) {
                    if H264Parser.parameterSets(annexB: packet.annexB) != nil { decoder.decode(config: packet.annexB) }
                    decoder.decode(frame: packet.annexB, pts: packet.timestamp)
                    decoder.waitForFrames()
                }
            }
            if !lock.withLock({ closed }) { throw Self.failure("模拟器视频通道已结束") }
        } catch {
            if !lock.withLock({ closed }) { continuation.finish(throwing: error) }
        }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            if client >= 0 { _ = shutdown(client, SHUT_RDWR) }
        }
        continuation.finish()
    }
    private static func failure(_ message: String) -> DeviceError { DeviceError(code: .CONNECTION_FAILED, message: message) }
}
