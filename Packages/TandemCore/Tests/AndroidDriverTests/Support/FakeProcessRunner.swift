import Foundation
import DeviceCore
@testable import AndroidDriver

final class FakeProcessRunner: ProcessRunner, @unchecked Sendable {
    struct Call: Equatable { var path: String; var args: [String] }
    enum Response { case result(ProcessResult), failure(any Error) }

    private let lock = NSLock()
    private var responses: [String: Response] = [:]
    private var sequences: [String: [Response]] = [:]
    private var _calls: [Call] = []
    private var streams: [String: [String]] = [:]
    private var byteStreams: [String: [Data]] = [:]

    private static func key(_ path: String, _ args: [String]) -> String { ([path] + args).joined(separator: "\u{1f}") }

    var calls: [Call] { lock.withLock { _calls } }

    func stub(_ path: String, _ args: [String], stdout: String = "", stderr: String = "", exitCode: Int32 = 0) {
        lock.withLock {
            responses[Self.key(path, args)] = .result(ProcessResult(exitCode: exitCode, stdout: Data(stdout.utf8), stderr: Data(stderr.utf8)))
        }
    }
    /// 依次返回给定 stdout；最后一项会一直重复。
    func stubSequence(_ path: String, _ args: [String], stdouts: [String]) {
        lock.withLock {
            sequences[Self.key(path, args)] = stdouts.map { .result(ProcessResult(exitCode: 0, stdout: Data($0.utf8), stderr: Data())) }
        }
    }
    func stubFailure(_ path: String, _ args: [String], error: any Error) {
        lock.withLock { responses[Self.key(path, args)] = .failure(error) }
    }
    func stubStream(_ path: String, _ args: [String], lines: [String]) {
        lock.withLock { streams[Self.key(path, args)] = lines }
    }
    func stubStreamBytes(_ path: String, _ args: [String], chunks: [Data]) {
        lock.withLock { byteStreams[Self.key(path, args)] = chunks }
    }

    struct Unstubbed: Error { var description: String }

    func run(_ executable: URL, _ args: [String], timeout: Duration) async throws -> ProcessResult {
        let k = Self.key(executable.path, args)
        let response = lock.withLock { () -> Response? in
            _calls.append(Call(path: executable.path, args: args))
            if var seq = sequences[k], !seq.isEmpty {
                let first = seq[0]
                if seq.count > 1 { seq.removeFirst(); sequences[k] = seq }
                return first
            }
            return responses[k]
        }
        switch response {
        case .result(let r): return r
        case .failure(let e): throw e
        case nil: throw Unstubbed(description: "unstubbed: \(executable.path) \(args)")
        }
    }

    func stream(_ executable: URL, _ args: [String]) throws -> RunningProcess {
        let lines = lock.withLock { () -> [String]? in
            _calls.append(Call(path: executable.path, args: args))
            return streams[Self.key(executable.path, args)]
        }
        guard let lines else { throw Unstubbed(description: "unstubbed stream") }
        return FakeRunningProcess(lines: lines)
    }

    func streamBytes(_ executable: URL, _ args: [String]) throws -> (bytes: AsyncStream<Data>, process: RunningProcess) {
        let chunks = lock.withLock { () -> [Data]? in
            _calls.append(Call(path: executable.path, args: args))
            return byteStreams[Self.key(executable.path, args)]
        }
        guard let chunks else { throw Unstubbed(description: "unstubbed streamBytes") }
        let bytes = AsyncStream<Data> { c in chunks.forEach { c.yield($0) }; c.finish() }
        return (bytes, FakeRunningProcess(lines: []))
    }
}

final class FakeRunningProcess: RunningProcess, @unchecked Sendable {
    let lines: AsyncStream<String>
    private let lock = NSLock()
    private var _terminated = false
    var terminated: Bool { lock.withLock { _terminated } }

    init(lines: [String]) {
        self.lines = AsyncStream { c in lines.forEach { c.yield($0) }; c.finish() }
    }
    func terminate() { lock.withLock { _terminated = true } }
}
