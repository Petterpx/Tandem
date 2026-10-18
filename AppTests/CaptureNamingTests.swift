import Foundation
import Testing
@testable import Tandem

@Suite struct CaptureNamingTests {
    // 2025-10-09 08:53:20 UTC
    private let date = Date(timeIntervalSince1970: 1_760_000_000)

    @Test func nameUsesDeviceAndTimestamp() {
        #expect(CaptureNaming.fileName(deviceName: "SM-G9730", date: date, ext: "png", timeZone: .gmt, isTaken: { _ in false })
                == "SM-G9730_20251009_085320.png")
    }

    @Test func illegalCharactersAreReplaced() {
        #expect(CaptureNaming.fileName(deviceName: "a/b:c", date: date, ext: "png", timeZone: .gmt, isTaken: { _ in false })
            .hasPrefix("a_b_c_"))
    }

    @Test func emptyNameFallsBackToDevice() {
        #expect(CaptureNaming.fileName(deviceName: "", date: date, ext: "mp4", timeZone: .gmt, isTaken: { _ in false })
                == "Device_20251009_085320.mp4")
    }

    @Test func sameSecondGetsSuffix() {
        let taken: Set = ["P_20251009_085320.png", "P_20251009_085320-2.png"]
        #expect(CaptureNaming.fileName(deviceName: "P", date: date, ext: "png", timeZone: .gmt, isTaken: taken.contains)
                == "P_20251009_085320-3.png")
    }
}
