import Foundation

public struct MdnsService: Equatable, Sendable {
    public enum Kind: Sendable { case pairing, connect }
    public var instance: String
    public var kind: Kind
    public var host: String
    public var port: UInt16

    public init(instance: String, kind: Kind, host: String, port: UInt16) {
        self.instance = instance
        self.kind = kind
        self.host = host
        self.port = port
    }
}

/// 解析 `adb mdns services` 输出。每行：实例名 <TAB> 服务类型 <TAB> host:port。
public enum MdnsParser {
    public static func parse(_ text: String) -> [MdnsService] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: { $0 == "\t" || $0 == " " }).map(String.init)
            guard fields.count >= 3 else { return nil }
            let type = fields[1].hasSuffix(".") ? String(fields[1].dropLast()) : fields[1]
            let kind: MdnsService.Kind
            switch type {
            case "_adb-tls-pairing._tcp": kind = .pairing
            case "_adb-tls-connect._tcp": kind = .connect
            default: return nil
            }
            let address = fields[2]
            guard let colon = address.lastIndex(of: ":"),
                  let port = UInt16(address[address.index(after: colon)...]) else { return nil }
            return MdnsService(instance: fields[0], kind: kind, host: String(address[..<colon]), port: port)
        }
    }
}
