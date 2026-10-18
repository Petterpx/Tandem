import Testing
import Foundation
@testable import ControlProtocol

@Test func requestRoundTrip() throws {
    let m = RPCMessage.request(id: 7, method: "tools/call", params: ["name": "tap", "arguments": ["x": 10, "y": 20.5]])
    #expect(try LineCodec.decode(LineCodec.encode(m)) == m)
    #expect(!String(decoding: try LineCodec.encode(m), as: UTF8.self).contains("\n"))
}

@Test func integralNumbersEncodeWithoutFraction() throws {
    let s = String(decoding: try LineCodec.encode(.response(id: 1, result: ["n": 3])), as: UTF8.self)
    #expect(s.contains("\"id\":1") && s.contains("\"n\":3"))
    #expect(!s.contains("3.0"))
}

@Test func stringIDIsPreserved() throws {
    let m = RPCMessage.request(id: "abc", method: "hello", params: nil)
    let back = try LineCodec.decode(LineCodec.encode(m))
    #expect(back.id == .string("abc"))
    #expect(back.isRequest)
}

@Test func nilFieldsAreOmitted() throws {
    let s = String(decoding: try LineCodec.encode(.notification(method: "tools/list_changed", params: nil)), as: UTF8.self)
    #expect(!s.contains("\"id\"") && !s.contains("\"result\"") && !s.contains("\"error\""))
    #expect(s.contains("\"jsonrpc\":\"2.0\""))
}

@Test func messageKinds() {
    #expect(RPCMessage.request(id: 1, method: "m", params: nil).isRequest)
    #expect(RPCMessage.notification(method: "m", params: nil).isNotification)
    #expect(RPCMessage.response(id: 1, result: nil).isResponse)
    let f = RPCMessage.failure(id: 1, error: RPCError(code: RPCError.methodNotFound, message: "x"))
    #expect(f.isResponse && f.error?.code == -32601)
}

@Test func failureTextFormat() {
    let r = ToolResult.failure(code: "AI_LOCKED", message: "设备已锁定，禁止 AI 操作", suggestion: "请在「AI」标签中关闭")
    #expect(r.isError && r.content == [.text("AI_LOCKED: 设备已锁定，禁止 AI 操作。建议：请在「AI」标签中关闭")])
    #expect(ToolResult.failure(code: "X", message: "m", suggestion: nil).content == [.text("X: m")])
}

@Test func imageContentUsesMCPShape() throws {
    let c = ToolContent.image(data: Data([1, 2, 3]), mimeType: "image/png")
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    let s = String(decoding: try enc.encode(c), as: UTF8.self)
    #expect(s == "{\"data\":\"AQID\",\"mimeType\":\"image\\/png\",\"type\":\"image\"}")
    #expect(try JSONDecoder().decode(ToolContent.self, from: enc.encode(c)) == c)
    let t = try JSONDecoder().decode(ToolContent.self, from: Data("{\"type\":\"text\",\"text\":\"hi\"}".utf8))
    #expect(t == .text("hi"))
}

@Test func jsonValueAccessors() {
    let v: JSONValue = ["a": 3, "b": 2.5, "c": "s", "d": true]
    #expect(v["a"]?.intValue == 3 && v["b"]?.intValue == nil && v["b"]?.doubleValue == 2.5)
    #expect(v["c"]?.stringValue == "s" && v["d"]?.boolValue == true)
    #expect(v.objectValue?.count == 4)
}

@Test func socketPathUnderApplicationSupport() {
    #expect(ControlPaths.socketURL(home: URL(fileURLWithPath: "/Users/u")).path == "/Users/u/Library/Application Support/Tandem/control.sock")
}
