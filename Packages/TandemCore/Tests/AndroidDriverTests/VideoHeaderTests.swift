import Foundation
import Testing
@testable import AndroidDriver

struct VideoHeaderTests {
    @Test func parsesSession() { #expect(VideoHeader.parse(Data([0x80,0,0,0, 0,0,0x04,0x38, 0,0,0x09,0x60])) == .session(width: 1080, height: 2400)) }
    @Test func parsesConfig() { #expect(VideoHeader.parse(Data([0x40,0,0,0,0,0,0,0, 0,0,0,0x1a])) == .media(config: true, keyFrame: false, pts: 0, size: 26)) }
    @Test func parsesKeyFrame() { #expect(VideoHeader.parse(Data([0x20,0,0,0,0,0,0x03,0xe8, 0,0,0x10,0])) == .media(config: false, keyFrame: true, pts: 1000, size: 4096)) }
    @Test func masksFlagsFromPts() {
        #expect(VideoHeader.parse(Data([0x60,0,0,0,0,0,0,0x07, 0,0,0,1])) == .media(config: true, keyFrame: true, pts: 7, size: 1))
    }
    @Test func rejectsWrongLength() {
        #expect(VideoHeader.parse(Data()) == nil)
        #expect(VideoHeader.parse(Data(repeating: 0, count: 11)) == nil)
        #expect(VideoHeader.parse(Data(repeating: 0, count: 13)) == nil)
    }
    @Test func parsesSlicedData() {
        let big = Data([9,9, 0x80,0,0,0, 0,0,0x04,0x38, 0,0,0x09,0x60])
        #expect(VideoHeader.parse(big[2...]) == .session(width: 1080, height: 2400))
    }
    @Test func codecIds() {
        #expect(VideoCodecId.h264 == 0x68323634 && VideoCodecId.disabled == 0 && VideoCodecId.configError == 1)
    }
}
