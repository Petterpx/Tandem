import Foundation

/// JSON-RPC 错误。同时作为 Swift Error 抛出。
public struct RPCError: Error, Codable, Sendable, Equatable {
    public var code: Int
    public var message: String
    public init(code: Int, message: String) { self.code = code; self.message = message }

    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let serverError = -32000
}

/// JSON-RPC 2.0 消息。请求 / 通知 / 响应共用一个结构，nil 字段不编码。
public struct RPCMessage: Codable, Sendable, Equatable {
    public var jsonrpc: String = "2.0"
    public var id: JSONValue?
    public var method: String?
    public var params: JSONValue?
    public var result: JSONValue?
    public var error: RPCError?

    public init(id: JSONValue? = nil, method: String? = nil, params: JSONValue? = nil,
                result: JSONValue? = nil, error: RPCError? = nil) {
        self.id = id; self.method = method; self.params = params; self.result = result; self.error = error
    }

    public static func request(id: JSONValue, method: String, params: JSONValue?) -> RPCMessage {
        RPCMessage(id: id, method: method, params: params)
    }
    public static func notification(method: String, params: JSONValue?) -> RPCMessage {
        RPCMessage(method: method, params: params)
    }
    public static func response(id: JSONValue, result: JSONValue?) -> RPCMessage {
        RPCMessage(id: id, result: result ?? .null)
    }
    public static func failure(id: JSONValue?, error: RPCError) -> RPCMessage {
        RPCMessage(id: id, error: error)
    }

    public var isRequest: Bool { id != nil && method != nil }
    public var isNotification: Bool { id == nil && method != nil }
    public var isResponse: Bool { id != nil && method == nil }
}

/// 一行一条消息的编解码。
public enum LineCodec {
    /// 编码为单行 JSON（不含换行；字符串内的换行已被转义）。
    public static func encode(_ m: RPCMessage) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        return try enc.encode(m)
    }
    public static func decode(_ line: Data) throws -> RPCMessage {
        try JSONDecoder().decode(RPCMessage.self, from: line)
    }
}
