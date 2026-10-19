import Foundation
import Testing
@testable import Tandem

@Suite struct LogExportTests {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }
    /// 2026-10-18 09:05:07 UTC
    private let date = Date(timeIntervalSince1970: 1_792_314_307)

    @Test func packageTarget() {
        let name = LogExport.fileName(device: "Pixel 7", target: .package("com.a.b"), date: date, calendar: calendar)
        #expect(name == "Pixel 7_com.a.b_20261018_090507.txt")
    }

    @Test func allTargetAndSanitizedDevice() {
        let name = LogExport.fileName(device: "a/b:c", target: .all, date: date, calendar: calendar)
        #expect(name == "a_b_c_all_20261018_090507.txt")
    }
}
