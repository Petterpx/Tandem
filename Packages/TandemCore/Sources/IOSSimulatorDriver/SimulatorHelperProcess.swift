import Darwin
import DeviceCore
import Foundation

protocol SimulatorHelperProcess: Sendable {
    var bytes: AsyncStream<Data> { get }
    var videoFrames: AsyncThrowingStream<VideoFrame, Error>? { get }
    func write(_ data: Data) async throws
    func terminate()
    func waitUntilExit() async
}

extension SimulatorHelperProcess {
    var videoFrames: AsyncThrowingStream<VideoFrame, Error>? { nil }
}

final class StdioSimulatorHelper: SimulatorHelperProcess, @unchecked Sendable {
    let bytes: AsyncStream<Data>
    private let output: AsyncStream<Data>.Continuation
    private let process: Process
    private let input: FileHandle
    private let read: FileHandle
    private let lock = NSLock()
    private let writer = DispatchQueue(label: "dev.tandem.simulator.stdin")
    private var closed = false
    private let video: SimulatorVideoConnection
    var videoFrames: AsyncThrowingStream<VideoFrame, Error>? { video.frames }

    init(url: URL, udid: String) throws {
        try SimctlClient.validate(udid)
        video = try SimulatorVideoConnection()
        video.start()
        process = Process()
        process.executableURL = url
        process.arguments = ["--udid", udid]
        var environment = ProcessInfo.processInfo.environment
        environment["TANDEM_VIDEO_SOCKET"] = video.path
        process.environment = environment
        let stdin = Pipe(), stdout = Pipe()
        input = stdin.fileHandleForWriting
        read = stdout.fileHandleForReading
        let descriptor = input.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
        process.standardInput = stdin
        process.standardOutput = stdout
        // Helper logs must not enter the JSON channel. Input/clipboard bodies are never logged.
        process.standardError = FileHandle.nullDevice
        (bytes, output) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(64))
        let continuation = output
        read.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                // Dropping arbitrary byte chunks corrupts NDJSON: fail closed if the consumer stalls.
                if case .dropped = continuation.yield(chunk) { continuation.finish() }
            }
        }
        do { try process.run() }
        catch {
            video.close()
            read.readabilityHandler = nil
            output.finish()
            throw DeviceError(code: .CONNECTION_FAILED, message: "模拟器 helper 启动失败：\(error.localizedDescription)", suggestion: "请重新构建 tandem-simulator，并确认使用 Apple Silicon 和 macOS 15 或更新系统")
        }
    }

    func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            writer.async { [self] in
                do {
                    try data.withUnsafeBytes { bytes in
                        var offset = 0
                        while offset < bytes.count {
                            guard !lock.withLock({ closed }) else { throw DeviceError(code: .CONNECTION_FAILED, message: "模拟器 helper 已退出") }
                            let count = Darwin.write(input.fileDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                            if count > 0 { offset += count; continue }
                            if count < 0 && errno == EINTR { continue }
                            if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                                var descriptor = pollfd(fd: input.fileDescriptor, events: Int16(POLLOUT), revents: 0)
                                _ = poll(&descriptor, 1, 50)
                                continue
                            }
                            throw DeviceError(code: .CONNECTION_FAILED, message: "模拟器 helper 输入管道已关闭")
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
        video.close()
        read.readabilityHandler = nil
        output.finish()
        // Closing stdin lets the helper release its owned touch and shut down HID normally.
        // Writes are nonblocking and observe closed within at most one poll interval.
        let input = input
        writer.async { try? input.close() }
        let process = process
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(500)) {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(2)) {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
    }
    func waitUntilExit() async {
        // terminate() guarantees TERM and KILL escalation. Do not start another HID
        // helper until the old child has exited and released its native session.
        while process.isRunning {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
    deinit { terminate() }
}
