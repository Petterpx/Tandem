import Foundation
import DeviceCore

public struct AdbDeviceEntry: Equatable, Sendable {
    public var serial: String
    public var state: String
    public var model: String?
    public var transportId: String?

    public init(serial: String, state: String, model: String? = nil, transportId: String? = nil) {
        self.serial = serial
        self.state = state
        self.model = model
        self.transportId = transportId
    }
}

public enum DeviceListParser {
    /// 解析 `adb devices -l` 输出，或 track-devices 的单个包体。
    public static func parseLong(_ text: String) -> [AdbDeviceEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 2, !tokens[0].hasPrefix("*"), tokens[0] != "List" else { return nil }
            var entry = AdbDeviceEntry(serial: tokens[0], state: tokens[1])
            for token in tokens.dropFirst(2) {
                if token.hasPrefix("model:") { entry.model = String(token.dropFirst("model:".count)) }
                else if token.hasPrefix("transport_id:") { entry.transportId = String(token.dropFirst("transport_id:".count)) }
            }
            return entry
        }
    }

    public static func connectionKind(serial: String) -> ConnectionKind {
        serial.contains(":") || serial.contains("._adb-tls-connect.") ? .wifi : .usb
    }

    public static func deviceState(_ raw: String) -> DeviceState {
        switch raw {
        case "device": .connected
        case "unauthorized", "authorizing": .unauthorized
        default: .offline
        }
    }
}

/// track-devices 流：4 位十六进制长度 + 包体；可跨 chunk 拼接。
public struct TrackDevicesDecoder: Sendable {
    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) -> [[AdbDeviceEntry]] {
        buffer.append(data)
        var snapshots: [[AdbDeviceEntry]] = []
        while buffer.count >= 4 {
            // 必须恰好是 4 位十六进制数字：Int(radix:) 还接受 "+"/"-" 前缀，负长度会让 prefix 崩溃。
            let header = buffer.prefix(4)
            guard header.allSatisfy(Self.isHexDigit),
                  let length = Int(String(decoding: header, as: UTF8.self), radix: 16) else {
                buffer.removeAll()  // 流已失步，丢弃，等待重启后重新同步
                break
            }
            guard buffer.count >= 4 + length else { break }
            let body = buffer.dropFirst(4).prefix(length)
            snapshots.append(DeviceListParser.parseLong(String(decoding: body, as: UTF8.self)))
            buffer = Data(buffer.dropFirst(4 + length))
        }
        return snapshots
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
    }
}
