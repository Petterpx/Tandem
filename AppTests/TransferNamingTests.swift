import DeviceCore
import Foundation
import Testing
@testable import Tandem

@Suite struct TransferNamingTests {
    @Test func candidateNames() {
        #expect(TransferNaming.candidate("a.jpg", 1) == "a (1).jpg")
        #expect(TransferNaming.candidate("README", 2) == "README (2)")
        #expect(TransferNaming.candidate("a.tar.gz", 1) == "a.tar (1).gz")
        #expect(TransferNaming.candidate("a.jpg", 0) == "a.jpg")
        #expect(TransferNaming.candidate(".bashrc", 1) == ".bashrc (1)")
    }

    @Test func uniqueLocalSkipsExisting() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(TransferNaming.uniqueLocal(in: dir, name: "a.jpg").lastPathComponent == "a.jpg")
        try Data().write(to: dir.appendingPathComponent("a.jpg"))
        try Data().write(to: dir.appendingPathComponent("a (1).jpg"))
        #expect(TransferNaming.uniqueLocal(in: dir, name: "a.jpg") == dir.appendingPathComponent("a (2).jpg"))
    }

    @Test func uniqueLocalSkipsReserved() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-\(UUID().uuidString)")
        let reserved: Set<String> = [dir.appendingPathComponent("x.log").standardizedFileURL.path]
        #expect(TransferNaming.uniqueLocal(in: dir, name: "x.log", reserved: reserved) == dir.appendingPathComponent("x (1).log"))
    }

    @Test func localNameRejectsDotSegments() throws {
        #expect(try TransferNaming.localName(forRemote: "/sdcard/x.log") == "x.log")
        for bad in ["/", "/sdcard/.", "/sdcard/..", "/.."] {
            #expect(throws: DeviceError(code: .INVALID_ARGUMENT, message: "设备路径不合法：\(bad)")) {
                try TransferNaming.localName(forRemote: bad)
            }
        }
    }
}
