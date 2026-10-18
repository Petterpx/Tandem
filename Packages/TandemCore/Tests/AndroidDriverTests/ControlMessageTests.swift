import Foundation
import Testing
@testable import AndroidDriver

struct ControlMessageTests {
    @Test func touchEncoding() {
        let m = ControlMessage.injectTouch(action: .down, pointerId: 0x1234567887654321, x: 100, y: 200, screenWidth: 1080, screenHeight: 1920,
                                           pressure: 1.0, actionButton: 1, buttons: 1)
        #expect([UInt8](m.encoded()) == [0x02, 0x00, 0x12,0x34,0x56,0x78,0x87,0x65,0x43,0x21, 0,0,0,0x64, 0,0,0,0xc8, 0x04,0x38, 0x07,0x80,
                                         0xff,0xff, 0,0,0,0x01, 0,0,0,0x01])
    }

    @Test func scrollEncoding() {
        let m = ControlMessage.injectScroll(x: 260, y: 1026, screenWidth: 1080, screenHeight: 1920, hscroll: 16, vscroll: -16, buttons: 1)
        #expect([UInt8](m.encoded()) == [0x03, 0,0,0x01,0x04, 0,0,0x04,0x02, 0x04,0x38, 0x07,0x80, 0x7f,0xff, 0x80,0x00, 0,0,0,0x01])
    }

    @Test func keycodeEncoding() {
        #expect([UInt8](ControlMessage.injectKeycode(action: .up, keycode: 66, repeat: 5, metaState: 0x41).encoded())
                == [0x00, 0x01, 0,0,0,0x42, 0,0,0,0x05, 0,0,0,0x41])
    }

    @Test func textEncodingTruncatesAtUtf8Boundary() {
        let text = String(repeating: "a", count: 299) + "中"
        let bytes = [UInt8](ControlMessage.injectText(text).encoded())
        #expect(bytes.count == 1 + 4 + 299)
        #expect(Array(bytes[0..<5]) == [0x01, 0, 0, 0x01, 0x2b])
    }

    @Test func textShorterThanLimitIsKept() {
        #expect([UInt8](ControlMessage.injectText("中").encoded()) == [0x01, 0,0,0,3, 0xe4,0xb8,0xad])
    }

    @Test func setClipboardEncoding() {
        #expect([UInt8](ControlMessage.setClipboard(sequence: 0x0102030405060708, text: "hello", paste: true).encoded())
                == [0x09, 1,2,3,4,5,6,7,8, 0x01, 0,0,0,0x05] + Array("hello".utf8))
    }

    @Test func setClipboardTruncatesAtLimitOnBoundary() {
        let text = String(repeating: "a", count: 262_130) + "中" // limit 262130; 中 would cross it
        let bytes = [UInt8](ControlMessage.setClipboard(sequence: 0, text: text, paste: false).encoded())
        #expect(bytes.count == 14 + 262_130)
        let text2 = String(repeating: "a", count: 262_129) + "中"
        let bytes2 = [UInt8](ControlMessage.setClipboard(sequence: 0, text: text2, paste: false).encoded())
        #expect(bytes2.count == 14 + 262_129)
    }

    @Test func getClipboardAndBack() {
        #expect([UInt8](ControlMessage.getClipboard(copyKey: 0).encoded()) == [0x08, 0x00])
        #expect([UInt8](ControlMessage.backOrScreenOn(.down).encoded()) == [0x04, 0x00])
    }
}
