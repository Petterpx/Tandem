import DeviceCore
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

@Suite struct LogCopyTextTests {
    @Test func copyTextUsesExportFormat() {
        let e = LogEntry(time: "10-18 09:05:07.123", pid: 12, tid: 13, level: .warn, tag: "T", message: "hi there")
        let lines: [LogLine] = [.entry(e, id: 1), .separator("—— 进程重启 ——", id: 2)]
        #expect(LogExport.text(lines) == "10-18 09:05:07.123 12 13 W T: hi there\n—— 进程重启 ——\n")
        #expect(LogExport.text([]) == "")
    }

    @Test func atBottomWithinOneRow() {
        #expect(LogExport.isAtBottom(contentHeight: 1000, visibleMaxY: 1000, rowHeight: 16))
        #expect(LogExport.isAtBottom(contentHeight: 1000, visibleMaxY: 985, rowHeight: 16))
        #expect(!LogExport.isAtBottom(contentHeight: 1000, visibleMaxY: 900, rowHeight: 16))
        #expect(LogExport.isAtBottom(contentHeight: 100, visibleMaxY: 300, rowHeight: 16))
    }
}
