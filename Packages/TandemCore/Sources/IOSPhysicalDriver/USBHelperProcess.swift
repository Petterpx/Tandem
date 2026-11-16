import Darwin
import DeviceCore
import Foundation

protocol USBHelperProcess: Sendable {
    var bytes: AsyncStream<Data> { get }
    var frames: AsyncThrowingStream<VideoFrame, any Error> { get }
    func write(_ data: Data) async throws
    func terminate()
    func waitUntilExit() async
}

final class StdioUSBHelper: USBHelperProcess, @unchecked Sendable {
    let bytes: AsyncStream<Data>
    let frames: AsyncThrowingStream<VideoFrame, any Error>
    private let messages: AsyncStream<Data>.Continuation
    private let video: AsyncThrowingStream<VideoFrame, any Error>.Continuation
    private let process = Process()
    private let input: FileHandle
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "dev.tandem.ios-usb.stdin")
    private var closed = false

    init(url: URL, udid: String, extraArguments: [String] = []) throws {
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        input = stdin.fileHandleForWriting
        _ = fcntl(input.fileDescriptor, F_SETFL, fcntl(input.fileDescriptor, F_GETFL) | O_NONBLOCK)
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        (bytes, messages) = AsyncStream.makeStream() // Never drop byte chunks / NDJSON.
        (frames, video) = AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        process.executableURL = url
        process.arguments = ["--udid", udid, "--framed-video"] + extraArguments
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let messages = messages, video = video
        DispatchQueue(label: "dev.tandem.ios-usb.stderr").async {
            let read = stderr.fileHandleForReading
            defer { try? read.close(); messages.finish() }
            while true {
                let data = read.availableData
                if data.isEmpty { return }
                messages.yield(data)
            }
        }
        DispatchQueue(label: "dev.tandem.ios-usb.hevc").async {
            let read = stdout.fileHandleForReading
            defer { try? read.close() }
            let decoder = USBHEVCDecoder { video.yield($0) }
            var packets = USBVideoPacketDecoder()
            do {
                while true {
                    let data = read.availableData
                    if data.isEmpty { break }
                    for packet in try packets.append(data) { try decoder.decode(packet) }
                }
                try packets.finish()
                video.finish()
            } catch { video.finish(throwing: error) }
        }
    }
    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            writer.async { [self] in
                do {
                    try data.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < bytes.count {
                            guard !lock.withLock({ closed }) else { throw protocolError("USB helper 输入通道已关闭") }
                            let count = Darwin.write(input.fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                            if count > 0 { offset += count; continue }
                            if count < 0 && errno == EINTR { continue }
                            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                                var fd = pollfd(fd: input.fileDescriptor, events: Int16(POLLOUT), revents: 0)
                                _ = poll(&fd, 1, 50)
                                continue
                            }
                            throw protocolError("USB helper 输入管道写入失败")
                        }
                    }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func terminate() {
        let shouldClose = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        guard shouldClose else { return }
        messages.finish()
        video.finish()
        let input = input
        writer.async { try? input.close() }
        // Native HID cleanup can take ~14s. Keep stdout/stderr draining while it exits.
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(3)) {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(20)) {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
    }
    func waitUntilExit() async {
        while process.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
    }
    deinit { terminate() }
}
