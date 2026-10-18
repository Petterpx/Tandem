import Testing
import Foundation
@testable import ControlProtocol

@Test func splitsLinesAndKeepsRemainder() {
    var r = LineReader()
    #expect(r.append(Data("a\nb".utf8)) == [Data("a".utf8)])
    #expect(r.append(Data("c\r\n\n".utf8)) == [Data("bc".utf8)])   // 去 \r，丢空行
}

@Test func utf8SplitAcrossChunks() {
    var r = LineReader()
    let bytes = Array("{\"t\":\"登录😀\"}\n".utf8)
    #expect(r.append(Data(bytes[0..<8])).isEmpty)     // 切在「登」的中间
    let lines = r.append(Data(bytes[8...]))
    #expect(lines.count == 1 && String(decoding: lines[0], as: UTF8.self) == "{\"t\":\"登录😀\"}")
}

@Test func manyLinesInOneChunk() {
    var r = LineReader()
    #expect(r.append(Data("1\n2\n3\n".utf8)) == [Data("1".utf8), Data("2".utf8), Data("3".utf8)])
}
