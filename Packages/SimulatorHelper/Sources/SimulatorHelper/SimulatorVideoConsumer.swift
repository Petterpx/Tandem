import Darwin
import FBControlCore
import Foundation

/// Native AnnexBFrameWriter calls consumeData once per complete H.264 access unit.
/// stdout remains a separate, small JSON control channel. Nothing runs on MainActor.
final class SimulatorVideoConsumer: DataConsumer, @unchecked Sendable {
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "dev.tandem.simulator.video", qos: .userInteractive)
    private let descriptor: Int32
    private var pending = 0
    private var closed = false
    private var wroteFrame = false

    var hasFrame: Bool { lock.withLock { wroteFrame } }
    var consumption: DataConsumption {
        // Let the native pre-encode capacity check see the actual queue depth.
        // The hard cap also covers already in-flight encoder callbacks.
        lock.withLock { .queued(unprocessed: closed ? 3 : pending) }
    }

    init(path: String? = ProcessInfo.processInfo.environment["TANDEM_VIDEO_SOCKET"]) throws {
        guard let path, path.utf8.count < 104 else {
            throw HelperFailure(code: "CONNECTION_FAILED", message: "Missing private simulator video channel")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HelperFailure(code: "CONNECTION_FAILED", message: "Cannot create video socket") }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: Array(path.utf8) + [0])
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { Darwin.close(fd); throw HelperFailure(code: "CONNECTION_FAILED", message: "Cannot connect private video channel") }
        descriptor = fd
        _ = fcntl(fd, F_SETNOSIGPIPE, 1)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var size: Int32 = 64 * 1024
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &size, socklen_t(MemoryLayout.size(ofValue: size)))
    }

    func consumeData(_ data: Data) {
        guard !data.isEmpty, data.count <= 16 * 1024 * 1024 else { close(); return }
        let accepted = lock.withLock {
            guard !closed else { return false }
            guard pending < 3 else { closed = true; _ = shutdown(descriptor, SHUT_RDWR); return false }
            pending += 1
            return true
        }
        guard accepted else { return }
        let timestamp = UInt64(ProcessInfo.processInfo.systemUptime * 1_000_000)
        writer.async { [self] in
            defer { lock.withLock { pending -= 1 } }
            guard !lock.withLock({ closed }) else { return }
            var length = UInt32(data.count).bigEndian
            var time = timestamp.bigEndian
            var header = Data([0x54, 0x44, 0x56, 1])
            withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
            withUnsafeBytes(of: &time) { header.append(contentsOf: $0) }
            // A stalled consumer fails closed after 250ms, never leaving stale frames
            // queued behind input. Bytes of a dependent H.264 frame are never dropped.
            let deadline = ProcessInfo.processInfo.systemUptime + 0.25
            if write(header, before: deadline), write(data, before: deadline) {
                lock.withLock { wroteFrame = true }
            } else { close() }
        }
    }

    private func write(_ data: Data, before deadline: Double) -> Bool {
        data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard !lock.withLock({ closed }), ProcessInfo.processInfo.systemUptime < deadline else { return false }
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count > 0 { offset += count; continue }
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    var pollDescriptor = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                    _ = poll(&pollDescriptor, 1, 10)
                    continue
                }
                return false
            }
            return true
        }
    }
    func consumeEndOfFile() { close() }
    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            _ = shutdown(descriptor, SHUT_RDWR)
        }
    }
    deinit { Darwin.close(descriptor) }
}
