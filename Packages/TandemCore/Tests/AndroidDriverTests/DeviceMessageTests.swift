import Foundation
import Testing
import DeviceCore
@testable import AndroidDriver

struct DeviceMessageTests {
    @Test func decodesClipboardAcrossChunks() throws {
        var d = DeviceMessageDecoder()
        #expect(try d.append(Data([0x00, 0,0,0,5, 0x68])) == [])
        #expect(try d.append(Data("ello".utf8)) == [.clipboard("hello")])
    }

    @Test func decodesAck() throws {
        var d = DeviceMessageDecoder()
        #expect(try d.append(Data([0x01, 1,2,3,4,5,6,7,8])) == [.ackClipboard(sequence: 0x0102030405060708)])
    }

    @Test func decodesMultipleMessagesInOneChunk() throws {
        var d = DeviceMessageDecoder()
        let data = Data([0x01, 0,0,0,0,0,0,0,1, 0x00, 0,0,0,1, 0x61])
        #expect(try d.append(data) == [.ackClipboard(sequence: 1), .clipboard("a")])
    }

    @Test func unknownTypeThrows() {
        var d = DeviceMessageDecoder()
        #expect(throws: DeviceError.self) { try d.append(Data([0x7f])) }
    }
}
