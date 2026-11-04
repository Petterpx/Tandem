import CoreVideo
import FBControlCore
import IOSurface
import Darwin
import Foundation
import Testing
@testable import SimulatorHelper

struct VideoConsumerTests {
    @Test func slowVideoReaderHasBoundedWritesAndClosesWithoutBlockingCaller() throws {
        let path = "/tmp/tandem-video-test-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(listener); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        #expect(listen(listener, 1) == 0)
        let consumer = try SimulatorVideoConsumer(path: path)
        let client = Darwin.accept(listener, nil, nil)
        defer { Darwin.close(client) }
        var size: Int32 = 4096
        _ = setsockopt(client, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout.size(ofValue: size)))
        let started = ProcessInfo.processInfo.systemUptime
        consumer.consumeData(Data(repeating: 1, count: 1024 * 1024))
        #expect(ProcessInfo.processInfo.systemUptime - started < 0.1)
        // Do not read until the writer's 250ms deadline has expired.
        usleep(400_000)
        #expect(!consumer.hasFrame)
        _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        var reachedEOF = false
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        while ProcessInfo.processInfo.systemUptime < deadline {
            let count = Darwin.read(client, &buffer, buffer.count)
            if count == 0 { reachedEOF = true; break }
            if count < 0 { usleep(1000) }
        }
        #expect(reachedEOF)
        consumer.close()
    }
}

extension VideoConsumerTests {
    @Test func staticSourceDeliversFirstAndFinalFramesWithoutAnotherSubmission() async throws {
        let path = "/tmp/tandem-static-test-\(UUID().uuidString).sock"
        let listener = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(listener); unlink(path) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        #expect(listen(listener, 1) == 0)
        let consumer = try SimulatorVideoConsumer(path: path)
        let client = Darwin.accept(listener, nil, nil)
        defer { Darwin.close(client) }
        let surface = try #require(IOSurfaceCreate([kIOSurfaceWidth: 64, kIOSurfaceHeight: 64,
            kIOSurfaceBytesPerElement: 4, kIOSurfaceBytesPerRow: 256,
            kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA, kIOSurfaceAllocSize: 16384] as CFDictionary))
        let failures = EncoderFailures()
        let encoder = SimulatorPreviewEncoder(consumer: consumer, logger: ControlCoreGlobalConfiguration.defaultLogger) { failures.append($0) }
        let firstStart = ProcessInfo.processInfo.systemUptime
        encoder.submit(surface: unsafeBitCast(surface, to: IOSurface.self), geometry: nil)
        for _ in 0..<100 {
            if (encoder.statistics["written"] ?? 0) >= 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect((encoder.statistics["written"] ?? 0) == 1)
        let firstMilliseconds = (ProcessInfo.processInfo.systemUptime - firstStart) * 1000
        #expect(firstMilliseconds < 1000)
        // No further render event follows this final submission.
        let lastStart = ProcessInfo.processInfo.systemUptime
        encoder.submit(surface: unsafeBitCast(surface, to: IOSurface.self), geometry: nil)
        for _ in 0..<100 {
            if (encoder.statistics["written"] ?? 0) >= 2 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect((encoder.statistics["written"] ?? 0) == 2)
        let finalMilliseconds = (ProcessInfo.processInfo.systemUptime - lastStart) * 1000
        #expect(finalMilliseconds < 1000)
        if ProcessInfo.processInfo.environment["TANDEM_STATIC_LATENCY"] == "1" {
            #expect(firstMilliseconds < 200)
            #expect(finalMilliseconds < 200)
        }
        print("TANDEM_STATIC_ENCODER first_ms=\(firstMilliseconds) final_ms=\(finalMilliseconds) stats=\(encoder.statistics)")
        #expect(failures.count == 0)
        await encoder.close()
    }
}

private final class EncoderFailures: @unchecked Sendable {
    private let lock = NSLock()
    private var errors: [any Error] = []
    var count: Int { lock.withLock { errors.count } }
    func append(_ error: any Error) { lock.withLock { errors.append(error) } }
}
