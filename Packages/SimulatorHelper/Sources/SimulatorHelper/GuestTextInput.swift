import Foundation
import Darwin

struct GuestTextResponse: Decodable, Sendable {
    let id: Int?
    let event: String?
    let ok: Bool?
    let code: String?
    let error: String?
    let text: String?
}

/// One session-owned guest process. No command is automatically retried, including
/// after a transport failure: the corresponding edit may already have reached UIKit.
@MainActor
final class GuestTextInput {
    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var writer: Task<Void, Never>?
    private var pending: CheckedContinuation<GuestTextResponse, Error>?
    private var expectedID: Int?
    private var sequence = 0
    private var ready = false
    private var broken = false
    var processIdentifier: Int32? { process?.processIdentifier }
    var isRunning: Bool { process?.isRunning == true }

    func start(simulatorUDID: String) async throws {
        let helper = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let directory = helper.deletingLastPathComponent()
        let guest = directory.lastPathComponent == "MacOS"
            ? directory.deletingLastPathComponent().appending(path: "Resources/Simulator/tandem-simulator-text")
            : directory.appending(path: "tandem-simulator-text")
        guard FileManager.default.isExecutableFile(atPath: guest.path) else {
            throw HelperFailure(code: "UNSUPPORTED", message: "The bundled simulator text helper is missing; rebuild the simulator helpers")
        }
        try await start(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["simctl", "spawn", simulatorUDID, guest.path])
    }

    func start(executable: URL, arguments: [String]) async throws {
        try Task.checkCancellation()
        guard process == nil else { throw HelperFailure.invalid("Native text session is already started") }
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        child.executableURL = executable
        child.arguments = arguments
        child.standardInput = stdin
        child.standardOutput = stdout
        // Error descriptions from private frameworks can contain user text.
        child.standardError = FileHandle.nullDevice
        try child.run()
        process = child
        input = stdin.fileHandleForWriting
        let handle = stdout.fileHandleForReading
        reader = Task.detached { [weak self] in
            do {
                var framer = LineFramer()
                while true {
                    var bytes = [UInt8](repeating: 0, count: 64 * 1024)
                    let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
                    if count == 0 { break }
                    if count < 0 { if errno == EINTR { continue }; break }
                    let data = Data(bytes.prefix(count))
                    for line in try framer.append(data) {
                        await self?.receive(line)
                    }
                }
            } catch { /* A closed pipe has the same uncertain-delivery semantics as EOF. */ }
            await self?.disconnect()
        }
        do {
            _ = try await withTaskCancellationHandler {
                try await waitForResponse(id: nil, timeout: .seconds(10))
            } onCancel: { Task { @MainActor in self.disconnect() } }
        }
        catch { await close(); throw error }
    }

    func request(command: String, text: String? = nil, paste: Bool = false) async throws -> GuestTextResponse {
        try Task.checkCancellation()
        guard ready, !broken, isRunning else { throw connectionFailure() }
        guard pending == nil else { throw HelperFailure(code: "AI_LOCKED", message: "A native text command is already in flight") }
        sequence += 1
        var object: [String: Any] = ["id": sequence, "command": command, "paste": paste]
        if let text { object["text"] = text }
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        // Install the continuation before writing, so even an immediate guest reply is retained.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                pending = continuation
                expectedID = sequence
                scheduleTimeout(id: sequence, timeout: .seconds(3))
                write(data)
            }
        } onCancel: { Task { @MainActor in self.disconnect() } }
    }

    private func write(_ data: Data) {
        guard let input else { disconnect(); return }
        let descriptor = fcntl(input.fileDescriptor, F_DUPFD_CLOEXEC, 0)
        guard descriptor >= 0 else { disconnect(); return }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            Darwin.close(descriptor)
            disconnect()
            return
        }
        writer = Task.detached { [weak self] in
            defer { Darwin.close(descriptor) }
            do {
                var offset = 0
                while offset < data.count {
                    try Task.checkCancellation()
                    let count = data.withUnsafeBytes { bytes in
                        Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                    }
                    if count > 0 { offset += count }
                    else if count < 0, errno == EINTR { continue }
                    else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                        try await Task.sleep(for: .milliseconds(1))
                    } else { await self?.disconnect(); return }
                }
            } catch { /* Cancellation releases the duplicated descriptor without replay. */ }
        }
    }

    private func waitForResponse(id: Int?, timeout: Duration) async throws -> GuestTextResponse {
        if ready { return GuestTextResponse(id: nil, event: "ready", ok: true, code: nil, error: nil, text: nil) }
        guard !broken else { throw connectionFailure() }
        return try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            expectedID = id
            scheduleTimeout(id: id, timeout: timeout)
        }
    }

    private func scheduleTimeout(id: Int?, timeout: Duration) {
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, self.pending != nil, self.expectedID == id else { return }
            self.disconnect()
        }
    }

    private func receive(_ line: Data) {
        guard let response = try? JSONDecoder().decode(GuestTextResponse.self, from: line) else { disconnect(); return }
        if response.event == "ready" {
            ready = true
            if expectedID == nil { pending?.resume(returning: response); pending = nil }
            return
        }
        if !ready, response.ok == false, let continuation = pending {
            pending = nil
            continuation.resume(throwing: HelperFailure(code: response.code ?? "CONNECTION_FAILED", message: response.error ?? "Native text helper failed to start"))
            disconnect()
            return
        }
        guard response.id == expectedID, let continuation = pending else { disconnect(); return }
        pending = nil
        if response.ok == true { continuation.resume(returning: response) }
        else { continuation.resume(throwing: HelperFailure(code: response.code ?? "CONNECTION_FAILED", message: response.error ?? "Native text delivery failed; verify the field before retrying")) }
    }

    private func connectionFailure() -> HelperFailure {
        HelperFailure(code: "CONNECTION_FAILED", message: "Native text connection closed; delivery may have completed. Verify the field before reconnecting")
    }

    private func disconnect() {
        broken = true
        ready = false
        pending?.resume(throwing: connectionFailure())
        pending = nil
        writer?.cancel()
        writer = nil
        try? input?.close()
        input = nil
        // EOF is the primary shutdown path; SIGTERM also restores guest AX state.
    }

    func close() async {
        if ready, !broken, pending == nil, isRunning { _ = try? await request(command: "quit") }
        disconnect()
        await waitForExit(timeout: .milliseconds(250))
        if isRunning { process?.terminate() }
        await waitForExit(timeout: .milliseconds(250))
        if isRunning, let process { Darwin.kill(process.processIdentifier, SIGKILL) }
        await waitForExit(timeout: .milliseconds(100))
        reader?.cancel()
    }

    private func waitForExit(timeout: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while isRunning, .now < deadline {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10)) { continuation.resume() }
            }
        }
    }
}
