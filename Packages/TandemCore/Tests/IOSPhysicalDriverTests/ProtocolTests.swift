import DeviceCore
import Foundation
import Testing
@testable import IOSPhysicalDriver

@Suite struct USBProtocolTests {
    @Test func textRequestPreservesUnicodeAndNeverImplicitlySubmits() throws {
        let text = "Hello 中文\n换行🙂👩🏽‍💻\t\"quoted\"\\"
        let data = try USBRequest(id: 19, op: "text", text: text).encodedLine()
        #expect(data.last == 10)
        #expect(data.filter { $0 == 10 }.count == 1)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["id"] as? Int == 19)
        #expect(object["op"] as? String == "text")
        #expect(object["text"] as? String == text)
        #expect(object["submit"] == nil)
        #expect(object["replace"] == nil)
        let submitted = try USBRequest(op: "text", text: text, submit: true).encodedLine()
        let explicit = try #require(JSONSerialization.jsonObject(with: submitted) as? [String: Any])
        #expect(explicit["submit"] as? Bool == true)
    }
    @Test func replacementRequestPreservesUnicodeAndOnlyOptsInExplicitly() throws {
        let text = "替换中文\n🙂👩🏽‍💻"
        let data = try USBRequest(op: "text", text: text, replace: true).encodedLine()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["op"] as? String == "text")
        #expect(object["text"] as? String == text)
        #expect(object["replace"] as? Bool == true)
        #expect(object["submit"] == nil)
    }
    @Test func textRequestEnforcesRawAndEscapedByteBoundsWithoutContentInErrors() throws {
        let boundary = String(repeating: "🙂", count: 2048)
        #expect(boundary.utf8.count == USBRequest.maximumTextBytes)
        #expect(try USBRequest(op: "text", text: boundary).encodedLine().count <= USBRequest.maximumLineBytes)
        for invalid in ["", "contains\0NUL", boundary + "a", String(repeating: "\n", count: 8192)] {
            do {
                _ = try USBRequest(op: "text", text: invalid).encodedLine()
                Issue.record("Invalid or oversized text accepted")
            } catch let error as DeviceError {
                #expect(error.code == .INVALID_ARGUMENT)
                if !invalid.isEmpty { #expect(!error.message.contains(invalid)) }
            }
        }
    }
    @Test func fragmentedMultiplePacketsPreservePTS() throws {
        let first = packet(Data([1, 2, 3]), pts: 123456), second = packet(Data([4]), pts: 999)
        var decoder = USBVideoPacketDecoder()
        var result: [USBVideoPacket] = []
        for byte in first + second { result += try decoder.append(Data([byte])) }
        #expect(result == [.init(payload: Data([1, 2, 3]), microseconds: 123456), .init(payload: Data([4]), microseconds: 999)])
        try decoder.finish()
    }
    @Test func invalidMagicLengthAndTruncationFail() throws {
        var magic = USBVideoPacketDecoder()
        #expect(throws: DeviceError.self) { try magic.append(Data(repeating: 0, count: 16)) }
        var length = USBVideoPacketDecoder()
        #expect(throws: DeviceError.self) { try length.append(Data([84,85,86,49,0xff,0xff,0xff,0xff] + Array(repeating: 0, count: 8))) }
        var truncated = USBVideoPacketDecoder()
        _ = try truncated.append(packet(Data([1,2]), pts: 0).dropLast())
        #expect(throws: DeviceError.self) { try truncated.finish() }
    }
    @Test func hevcMixedStartCodesConfigurationAndSliceAVCC() throws {
        let data = Data([0,0,0,1,64,1,9, 0,0,1,66,1,8, 0,0,0,1,68,1,7, 0,0,1,38,1,6])
        let nals = try HEVCParser.nals(data)
        let config = try #require(HEVCParser.parameterSets(nals))
        #expect(config.vps == Data([64,1,9]))
        #expect(config.sps == Data([66,1,8]))
        #expect(config.pps == Data([68,1,7]))
        #expect(HEVCParser.avcc(nals) == Data([0,0,0,3,38,1,6]))
        #expect(HEVCParser.parameterSets(Array(nals.prefix(2))) == nil)
        #expect(throws: DeviceError.self) { try HEVCParser.nals(Data([0,0,1,64])) }
        #expect(throws: DeviceError.self) { try HEVCParser.nals(Data([64,1,9])) }
    }
    @Test func parameterSetsAccumulateAcrossAccessUnits() throws {
        var parameters = HEVCConfigurationAccumulator()
        #expect(parameters.append([Data([64,1,9])]) == nil)
        #expect(parameters.append([Data([66,1,8])]) == nil)
        let completeValue = parameters.append([Data([68,1,7])])
        let complete = try #require(completeValue)
        #expect(complete.vps == Data([64,1,9]))
        let updatedValue = parameters.append([Data([66,1,6])])
        let updated = try #require(updatedValue)
        #expect(updated.sps == Data([66,1,6]))
        #expect(updated.pps == complete.pps)
    }
    @Test func ndjsonFragmentationUnknownAckAndTruncation() throws {
        var decoder = USBMessageDecoder()
        #expect(try decoder.append(Data(#"{"event":"input_ack","id":99,"sent":true}"#.utf8)).isEmpty)
        let messages = try decoder.append(Data("\n{\"event\":\"ready\"}\n".utf8))
        #expect(messages.count == 2)
        #expect(messages.first?.id == 99)
        try decoder.finish()
        _ = try decoder.append(Data("{".utf8))
        #expect(throws: DeviceError.self) { try decoder.finish() }
    }
    @Test func touchOwnerCannotBeStolenOrReleased() throws {
        var owner = USBTouchOwnership()
        try owner.begin(.down, pointer: .ai)
        #expect(throws: DeviceError.self) { try owner.begin(.up, pointer: .finger) }
        #expect(owner.owner == .ai)
        try owner.begin(.move, pointer: .ai)
        try owner.begin(.up, pointer: .ai)
        owner.finish(.up)
        #expect(owner.owner == nil)
        #expect(throws: DeviceError.self) { try owner.begin(.move, pointer: .ai) }
        try owner.begin(.down, pointer: .finger)
        owner.reset()
        #expect(owner.owner == nil)
    }
    @Test func discoveryDeduplicatesAndRejectsNetworkTransports() throws {
        let data = Data(#"[{"udid":"A","device_id":1,"connection":"usb"},{"udid":"A","connection":"usb"},{"udid":"B","connection":"network"}]"#.utf8)
        let devices = try IOSPhysicalDriver.devices(data, capabilities: [.mirror])
        #expect(devices.map(\.serial) == ["A"])
        #expect(devices.first?.connection == .usb)
        let driver = IOSPhysicalDriver(helperURL: URL(fileURLWithPath: "/does-not-exist"))
        #expect(driver.availabilityError?.code == .UNSUPPORTED)
        #expect(driver.capabilities.isEmpty)
        let available = IOSPhysicalDriver(helperURL: URL(fileURLWithPath: "/usr/bin/true"))
        #expect(available.capabilities.contains(.appLaunch))
        #expect(!available.capabilities.contains(.apps))
    }
}

func packet(_ payload: Data, pts: UInt64) -> Data {
    var output = Data([84,85,86,49]), size = UInt32(payload.count).bigEndian, pts = pts.bigEndian
    withUnsafeBytes(of: &size) { output.append(contentsOf: $0) }
    withUnsafeBytes(of: &pts) { output.append(contentsOf: $0) }
    output.append(payload)
    return output
}
