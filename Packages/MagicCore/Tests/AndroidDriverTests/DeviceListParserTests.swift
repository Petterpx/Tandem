import Testing
import Foundation
import DeviceCore
@testable import AndroidDriver

private func fixture() throws -> String {
    let url = try #require(Bundle.module.url(forResource: "devices-l", withExtension: "txt", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8)
}

@Test func parsesLongFormat() throws {
    let e = DeviceListParser.parseLong(try fixture())
    #expect(e.count == 5)
    #expect(e[0].model == "Pixel_8")
    #expect(e[0].transportId == "3")
    #expect(e[1].state == "unauthorized")
    #expect(e[1].model == nil)
}

@Test func classifiesWifiSerials() {
    #expect(DeviceListParser.connectionKind(serial: "192.168.1.23:5555") == .wifi)
    #expect(DeviceListParser.connectionKind(serial: "adb-R5CT1234567-AbCdEf._adb-tls-connect._tcp") == .wifi)
    #expect(DeviceListParser.connectionKind(serial: "R5CT1234567") == .usb)
}

@Test func mapsDeviceStates() {
    #expect(DeviceListParser.deviceState("device") == .connected)
    #expect(DeviceListParser.deviceState("unauthorized") == .unauthorized)
    #expect(DeviceListParser.deviceState("authorizing") == .unauthorized)
    #expect(DeviceListParser.deviceState("offline") == .offline)
    #expect(DeviceListParser.deviceState("recovery") == .offline)
}

@Test func decoderHandlesSplitChunksAndEmptyList() {
    var d = TrackDevicesDecoder()
    #expect(d.append(Data("0000".utf8)) == [[]])
    let body = "R5CT1234567\tdevice\n"
    let framed = String(format: "%04x", body.utf8.count) + body
    #expect(d.append(Data(framed.prefix(6).utf8)) == [])
    #expect(d.append(Data(framed.dropFirst(6).utf8)).first?.first?.serial == "R5CT1234567")
}
