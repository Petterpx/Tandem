import Foundation

public struct ToolDescriptor: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
    }
}

/// MCP 工具结果内容：文本或图片，编码为 MCP 规定的形状。
public enum ToolContent: Codable, Sendable, Equatable {
    case text(String)
    case image(data: Data, mimeType: String)

    private enum Keys: String, CodingKey { case type, text, data, mimeType }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text":
            self = .text(try c.decode(String.self, forKey: .text))
        case "image":
            let b64 = try c.decode(String.self, forKey: .data)
            guard let d = Data(base64Encoded: b64) else {
                throw DecodingError.dataCorruptedError(forKey: .data, in: c, debugDescription: "invalid base64")
            }
            self = .image(data: d, mimeType: try c.decode(String.self, forKey: .mimeType))
        case let t:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown content type \(t)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let s):
            try c.encode("text", forKey: .type)
            try c.encode(s, forKey: .text)
        case .image(let d, let m):
            try c.encode("image", forKey: .type)
            try c.encode(d.base64EncodedString(), forKey: .data)
            try c.encode(m, forKey: .mimeType)
        }
    }
}

public struct ToolResult: Codable, Sendable, Equatable {
    public var content: [ToolContent]
    public var isError: Bool
    public init(content: [ToolContent], isError: Bool = false) {
        self.content = content; self.isError = isError
    }

    public static func text(_ s: String) -> ToolResult { ToolResult(content: [.text(s)]) }

    /// 错误文字格式：`CODE: 信息。建议：…`
    public static func failure(code: String, message: String, suggestion: String?) -> ToolResult {
        var s = "\(code): \(message)"
        if let suggestion { s += "。建议：\(suggestion)" }
        return ToolResult(content: [.text(s)], isError: true)
    }
}

public struct ToolsListResult: Codable, Sendable, Equatable {
    public var tools: [ToolDescriptor]
    public init(tools: [ToolDescriptor]) { self.tools = tools }
}

public struct ToolCallParams: Codable, Sendable, Equatable {
    public var name: String
    public var arguments: [String: JSONValue]?
    public init(name: String, arguments: [String: JSONValue]? = nil) {
        self.name = name; self.arguments = arguments
    }
}

public struct HelloParams: Codable, Sendable {
    public var protocolVersion: Int
    public var clientName: String?
    public var clientVersion: String?
    public init(protocolVersion: Int, clientName: String? = nil, clientVersion: String? = nil) {
        self.protocolVersion = protocolVersion; self.clientName = clientName; self.clientVersion = clientVersion
    }
}

public struct HelloResult: Codable, Sendable {
    public var protocolVersion: Int
    public var appVersion: String
    public init(protocolVersion: Int, appVersion: String) {
        self.protocolVersion = protocolVersion; self.appVersion = appVersion
    }
}

/// App 控制通道上的方法名。
public enum ControlMethod {
    public static let hello = "hello"
    public static let toolsList = "tools/list"
    public static let toolsCall = "tools/call"
    public static let toolsListChanged = "tools/list_changed"
}

public enum ControlProtocolVersion {
    public static let current = 1
}
