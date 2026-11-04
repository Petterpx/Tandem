import DeviceCore
import Foundation

struct SimulatorVideoPacket: Sendable {
    let annexB: Data
    /// Encoder output time, host monotonic microseconds; excludes capture/encode time.
    let timestamp: UInt64
}

struct SimulatorVideoPacketDecoder {
    static let maximumPayload = 16 * 1024 * 1024
    private var buffer = Data()
    mutating func append(_ data: Data) throws -> [SimulatorVideoPacket] {
        buffer.append(data)
        var packets: [SimulatorVideoPacket] = []
        var offset = 0
        while buffer.count - offset >= 16 {
            let bytes = buffer[buffer.startIndex + offset ..< buffer.startIndex + offset + 16]
            guard bytes.prefix(4).elementsEqual([0x54, 0x44, 0x56, 1]) else { throw invalid() }
            let header = Array(bytes)
            let length = header[4..<8].reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= Self.maximumPayload else { throw invalid() }
            guard buffer.count - offset >= 16 + length else { break }
            let timestamp = header[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            packets.append(.init(annexB: Data(buffer[buffer.startIndex + offset + 16 ..< buffer.startIndex + offset + 16 + length]), timestamp: timestamp))
            offset += 16 + length
        }
        if offset > 0 { buffer.removeFirst(offset) }
        guard buffer.count <= Self.maximumPayload + 16 else { throw invalid() }
        return packets
    }
    func finish() throws { guard buffer.isEmpty else { throw invalid() } }
    private func invalid() -> DeviceError { DeviceError(code: .CONNECTION_FAILED, message: "模拟器视频数据损坏或超出大小限制") }
}
