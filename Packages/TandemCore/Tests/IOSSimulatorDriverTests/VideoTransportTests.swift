import Darwin
import DeviceCore
import Foundation
import Testing
@testable import IOSSimulatorDriver

struct VideoTransportTests {
    @Test func binaryPacketsSurviveFragmentedAndCoalescedSocketReads() throws {
        var decoder = SimulatorVideoPacketDecoder()
        let payload = Data([0, 0, 0, 1, 0x65, 0x43])
        let packet = Data([0x54,0x44,0x56,1, 0,0,0,6, 0,0,0,0,0,0,0,42]) + payload
        var frames: [SimulatorVideoPacket] = []
        for byte in packet + packet { frames += try decoder.append(Data([byte])) }
        #expect(frames.count == 2)
        #expect(frames.first?.annexB == payload)
        #expect(frames.first?.timestamp == 42)
        try decoder.finish()
    }
    @Test func malformedAndTruncatedPacketsFailClosed() throws {
        var invalid = SimulatorVideoPacketDecoder()
        #expect(throws: (any Error).self) { _ = try invalid.append(Data(repeating: 255, count: 16)) }
        var oversized = SimulatorVideoPacketDecoder()
        #expect(throws: (any Error).self) {
            _ = try oversized.append(Data([0x54,0x44,0x56,1, 0x7f,0xff,0xff,0xff, 0,0,0,0,0,0,0,0]))
        }
        var partial = SimulatorVideoPacketDecoder()
        _ = try partial.append(Data([0x54]))
        #expect(throws: (any Error).self) { try partial.finish() }
    }
}

extension VideoTransportTests {
    @Test func closingUnconnectedSocketRemovesItsPrivateDirectory() async throws {
        let connection = try SimulatorVideoConnection()
        let path = connection.path
        #expect(FileManager.default.fileExists(atPath: path))
        connection.start()
        connection.close()
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path))
    }
}

extension VideoTransportTests {
    @Test func realSocketEOFWithPartialPacketFailsAndRemovesDirectory() async throws {
        let connection = try SimulatorVideoConnection()
        let path = connection.path
        connection.start()
        let client = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { Darwin.close(client); connection.close() }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(client, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(connected == 0)
        var byte: UInt8 = 0x54
        #expect(Darwin.write(client, &byte, 1) == 1)
        _ = shutdown(client, SHUT_WR)
        var iterator = connection.frames.makeAsyncIterator()
        do {
            _ = try await iterator.next()
            Issue.record("A truncated video packet must terminate the stream with an error")
        } catch { #expect(error is DeviceError) }
        for _ in 0..<100 {
            if !FileManager.default.fileExists(atPath: path) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
