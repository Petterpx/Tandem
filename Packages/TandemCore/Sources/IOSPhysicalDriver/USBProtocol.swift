import DeviceCore
import Foundation

struct USBVideoPacket: Equatable, Sendable {
    let payload: Data
    let microseconds: UInt64
}

/// stdout is a lossless stream of 16-byte TUV1 headers followed by Annex-B access units.
struct USBVideoPacketDecoder {
    static let maximumPayload = 16 * 1024 * 1024
    private var buffer = Data()
    mutating func append(_ bytes: Data) throws -> [USBVideoPacket] {
        buffer.append(bytes)
        var packets: [USBVideoPacket] = []
        var consumed = 0
        while buffer.count - consumed >= 16 {
            let header = Array(buffer[consumed..<(consumed + 16)])
            guard Array(header.prefix(4)) == [84, 85, 86, 49] else { throw protocolError("无效视频帧标识") }
            let length = header[4..<8].reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= Self.maximumPayload else { throw protocolError("视频帧长度超限") }
            guard buffer.count - consumed - 16 >= length else { break }
            let pts = header[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            packets.append(.init(payload: Data(buffer[(consumed + 16)..<(consumed + 16 + length)]), microseconds: pts))
            consumed += 16 + length
        }
        if consumed > 0 { buffer = Data(buffer.dropFirst(consumed)) }
        guard buffer.count <= Self.maximumPayload + 16 else { throw protocolError("视频流缓冲超限") }
        return packets
    }
    func finish() throws {
        guard buffer.isEmpty else { throw protocolError("视频帧被截断") }
    }
}

struct USBMessage: Decodable, Sendable {
    let event: String?
    let id: Int?
    let sent: Bool?
    let error: String?
    let message: String?
}

struct USBMessageDecoder {
    private var buffer = Data()
    mutating func append(_ bytes: Data) throws -> [USBMessage] {
        buffer.append(bytes)
        var result: [USBMessage] = []
        while let index = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<index])
            buffer = Data(buffer.dropFirst(index + 1))
            guard line.count <= 1024 * 1024 else { throw protocolError("helper 消息超限") }
            if !line.isEmpty { result.append(try JSONDecoder().decode(USBMessage.self, from: line)) }
        }
        guard buffer.count <= 1024 * 1024 else { throw protocolError("helper 消息超限") }
        return result
    }
    func finish() throws { guard buffer.isEmpty else { throw protocolError("helper 消息被截断") } }
}

struct USBRequest: Encodable, Sendable {
    static let maximumTextBytes = 8 * 1024
    static let maximumLineBytes = 16 * 1024
    var id = 0
    let op: String
    var phase: String?
    var x: Double?
    var y: Double?
    var button: String?
    var key: String?
    var text: String?
    var submit: Bool?
    var replace: Bool?

    func encodedLine() throws -> Data {
        if op == "text" {
            guard let text, !text.isEmpty, !text.utf8.contains(0), text.utf8.count <= Self.maximumTextBytes else {
                throw DeviceError(code: .INVALID_ARGUMENT, message: "iPhone 文本须为非空、不含 NUL 且不超过 8192 UTF-8 字节")
            }
        }
        var data = try JSONEncoder().encode(self)
        // JSON escaping can make even a short UTF-8 string exceed the helper's line bound.
        guard data.count < Self.maximumLineBytes else {
            throw DeviceError(code: .INVALID_ARGUMENT, message: "iPhone 输入请求编码后超过 16384 字节")
        }
        data.append(10)
        return data
    }
}

func protocolError(_ message: String) -> DeviceError { DeviceError(code: .CONNECTION_FAILED, message: message) }

/// Host owns the one raw HID contact; an unrelated source cannot move or release it.
struct USBTouchOwnership {
    private(set) var owner: TouchPointer?
    mutating func begin(_ phase: TouchPhase, pointer: TouchPointer) throws {
        if let owner, owner != pointer { throw DeviceError(code: .AI_LOCKED, message: "触控正由另一输入源使用") }
        switch phase {
        case .down:
            guard owner == nil else { throw DeviceError(code: .AI_LOCKED, message: "已有进行中的触控") }
            owner = pointer
        case .move, .up:
            guard owner == pointer else { throw DeviceError(code: .INVALID_ARGUMENT, message: "触控尚未按下") }
        }
    }
    mutating func finish(_ phase: TouchPhase) { if phase == .up { owner = nil } }
    mutating func reset() { owner = nil }
}
