import Foundation
import Testing
@testable import AndroidDriver

struct H264ParserTests {
    @Test func splitsMixedStartCodes() { #expect(H264Parser.nalUnits(annexB: Data([0,0,0,1,0x67,0xAA, 0,0,1,0x68,0xBB])) == [Data([0x67,0xAA]), Data([0x68,0xBB])]) }
    @Test func ignoresLeadingGarbage() { #expect(H264Parser.nalUnits(annexB: Data([0xFF,0xEE, 0,0,1,0x65,1])) == [Data([0x65,1])]) }
    @Test func dropsEmptyNals() { #expect(H264Parser.nalUnits(annexB: Data([0,0,1, 0,0,1,0x41,2, 0,0,0,1])) == [Data([0x41,2])]) }
    @Test func noStartCodeYieldsNothing() { #expect(H264Parser.nalUnits(annexB: Data([1,2,3])).isEmpty && H264Parser.nalUnits(annexB: Data()).isEmpty) }
    @Test func nalTypeMasks() { #expect(H264Parser.nalType(Data([0x67])) == 7 && H264Parser.nalType(Data([0x65])) == 5) }
    @Test func avccPrefixesLengths() { #expect([UInt8](H264Parser.avcc(fromAnnexB: Data([0,0,0,1,0x65,1,2]))) == [0,0,0,3,0x65,1,2]) }
    @Test func avccMultipleNals() { #expect([UInt8](H264Parser.avcc(fromAnnexB: Data([0,0,1,0x67,9, 0,0,0,1,0x68,8,7]))) == [0,0,0,2,0x67,9, 0,0,0,3,0x68,8,7]) }
    @Test func extractsParameterSets() { let p = H264Parser.parameterSets(annexB: Data([0,0,0,1,0x67,9, 0,0,0,1,0x68,8])); #expect(p?.sps == Data([0x67,9]) && p?.pps == Data([0x68,8])) }
    @Test func missingPpsIsNil() { #expect(H264Parser.parameterSets(annexB: Data([0,0,0,1,0x67,9])) == nil) }
}
