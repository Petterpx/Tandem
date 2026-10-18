import Foundation
import DeviceCore

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: Data
    public var stdoutString: String { String(decoding: stdout, as: UTF8.self) }

    public init(exitCode: Int32, stdout: Data, stderr: Data) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol RunningProcess: Sendable {
    /// stdout 与 stderr 合并，按行输出。
    var lines: AsyncStream<String> { get }
    func terminate()
}

public protocol ProcessRunner: Sendable {
    /// 超时会终止进程并抛出 `DeviceError.timeout`。
    func run(_ executable: URL, _ args: [String], timeout: Duration) async throws -> ProcessResult
    func stream(_ executable: URL, _ args: [String]) throws -> RunningProcess
    /// 原始 stdout 字节流（给 track-devices 用）。
    func streamBytes(_ executable: URL, _ args: [String]) throws -> (bytes: AsyncStream<Data>, process: RunningProcess)
}

/// 基于 Foundation.Process 的实现；启动失败（如 bad CPU type）会抛错而不是崩溃。
public struct SystemProcessRunner: ProcessRunner {
    public init() {}

    public func run(_ executable: URL, _ args: [String], timeout: Duration) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        let state = RunState()
        let collector = Collector()

        // 全部基于事件回调（readabilityHandler / terminationHandler），不阻塞任何线程，
        // 因此大量挂起的子进程也不会饿死超时计时器。
        outPipe.fileHandleForReading.readabilityHandler = { collector.read($0, isOut: true) }
        errPipe.fileHandleForReading.readabilityHandler = { collector.read($0, isOut: false) }
        process.terminationHandler = { _ in collector.partDone() }

        do { try process.run() } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw error
        }

        let timer = DispatchWorkItem {
            state.markTimedOut()
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + .nanoseconds(Int(min(timeout.nanoseconds, UInt64(Int.max / 2)))), execute: timer)

        let (stdout, stderr) = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<(Data, Data), Never>) in
                collector.onFinish(cont)
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        timer.cancel()

        if state.timedOut {
            throw DeviceError.timeout("\(executable.lastPathComponent) \(args.joined(separator: " "))")
        }
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    public func stream(_ executable: URL, _ args: [String]) throws -> RunningProcess {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let assembler = LineAssembler()
        let (lines, continuation) = AsyncStream<String>.makeStream()
        try process.run()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                assembler.flush().forEach { continuation.yield($0) }
                continuation.finish()
            } else {
                assembler.feed(data).forEach { continuation.yield($0) }
            }
        }
        continuation.onTermination = { _ in
            if process.isRunning { process.terminate() }
        }
        return SystemRunningProcess(process: process, lines: lines)
    }

    public func streamBytes(_ executable: URL, _ args: [String]) throws -> (bytes: AsyncStream<Data>, process: RunningProcess) {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let (bytes, continuation) = AsyncStream<Data>.makeStream()
        try process.run()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                continuation.finish()
            } else {
                continuation.yield(data)
            }
        }
        continuation.onTermination = { _ in
            if process.isRunning { process.terminate() }
        }
        return (bytes, SystemRunningProcess(process: process, lines: AsyncStream { $0.finish() }))
    }
}

private extension Duration {
    var nanoseconds: UInt64 {
        let c = components
        return UInt64(max(0, c.seconds)) &* 1_000_000_000 &+ UInt64(max(0, c.attoseconds / 1_000_000_000))
    }
}

private final class Collector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    private var pending = 3  // stdout EOF、stderr EOF、进程退出
    private var cont: CheckedContinuation<(Data, Data), Never>?

    func read(_ handle: FileHandle, isOut: Bool) {
        let data = handle.availableData
        if data.isEmpty {
            handle.readabilityHandler = nil
            partDone()
        } else {
            lock.withLock { if isOut { out.append(data) } else { err.append(data) } }
        }
    }

    func partDone() {
        let finish: (CheckedContinuation<(Data, Data), Never>, Data, Data)? = lock.withLock {
            pending -= 1
            guard pending == 0, let c = cont else { return nil }
            cont = nil
            return (c, out, err)
        }
        if let (c, o, e) = finish { c.resume(returning: (o, e)) }
    }

    func onFinish(_ c: CheckedContinuation<(Data, Data), Never>) {
        let ready: (Data, Data)? = lock.withLock {
            if pending == 0 { return (out, err) }
            cont = c
            return nil
        }
        if let ready { c.resume(returning: ready) }
    }
}

private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var _timedOut = false
    var timedOut: Bool { lock.withLock { _timedOut } }
    func markTimedOut() { lock.withLock { _timedOut = true } }
}

private final class LineAssembler: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func feed(_ data: Data) -> [String] {
        lock.withLock {
            buffer.append(data)
            var out: [String] = []
            while let i = buffer.firstIndex(of: 0x0A) {
                out.append(String(decoding: buffer[buffer.startIndex..<i], as: UTF8.self))
                buffer.removeSubrange(buffer.startIndex...i)
            }
            return out
        }
    }

    func flush() -> [String] {
        lock.withLock {
            defer { buffer.removeAll() }
            return buffer.isEmpty ? [] : [String(decoding: buffer, as: UTF8.self)]
        }
    }
}

private final class SystemRunningProcess: RunningProcess, @unchecked Sendable {
    let process: Process
    let lines: AsyncStream<String>

    init(process: Process, lines: AsyncStream<String>) {
        self.process = process
        self.lines = lines
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
