import Foundation
import DeviceCore

/// scrcpy 设备 -> 主机消息（对应 app/src/device_msg.c）。
enum DeviceMessage: Equatable, Sendable {
    case clipboard(String)
    case ackClipboard(sequence: UInt64)
}

/// 流式解码器：不完整的数据缓存等待，未知 type 抛错（无法恢复）。
struct DeviceMessageDecoder: Sendable {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [DeviceMessage] {
        buffer.append(data)
        var messages: [DeviceMessage] = []
        var offset = 0
        loop: while offset < buffer.count {
            let base = buffer.startIndex + offset
            let available = buffer.count - offset
            switch buffer[base] {
            case 0:
                guard available >= 5 else { break loop }
                let length = Int(readBE(base + 1, count: 4))
                guard available - 5 >= length else { break loop }
                let payload = buffer[(base + 5)..<(base + 5 + length)]
                messages.append(.clipboard(String(decoding: payload, as: UTF8.self)))
                offset += 5 + length
            case 1:
                guard available >= 9 else { break loop }
                messages.append(.ackClipboard(sequence: readBE(base + 1, count: 8)))
                offset += 9
            case let type:
                buffer.removeAll()
                throw DeviceError.connectionFailed("未知的设备消息类型：\(type)")
            }
        }
        buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + offset))
        return messages
    }

    private func readBE(_ index: Int, count: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0..<count { value = value << 8 | UInt64(buffer[index + i]) }
        return value
    }
}
