import Foundation
import Testing
@testable import DeviceCore

@Test func devicePathValidation() throws {
    #expect(try DevicePath.validate("/sdcard/a b'c.jpg") == "/sdcard/a b'c.jpg")
    for bad in ["sdcard/x", "/a\nb", "", "/a\rb", "/a\0b"] {
        do {
            _ = try DevicePath.validate(bad)
            Issue.record("应当抛错：\(bad)")
        } catch let error as DeviceError {
            #expect(error.code == .INVALID_ARGUMENT)
            #expect(error.message == "设备路径不合法：\(bad)")
        }
    }
}

@Test func logLevelOrdering() {
    #expect(LogLevel.warn > LogLevel.info)
    #expect(LogLevel.verbose < LogLevel.fatal)
    #expect(LogLevel(rawValue: "E") == .error)
}

@Test func progressFraction() {
    #expect(TransferProgress(bytes: 50, total: 200).fraction == 0.25)
    #expect(TransferProgress(bytes: 50, total: nil).fraction == nil)
    #expect(TransferProgress(bytes: 50, total: 0).fraction == nil)
}

@Test func newDefaultsAreUnsupported() async {
    let actions = FakeActions(serial: "S")
    do {
        _ = try await actions.listDirectory("/sdcard")
        Issue.record("应当抛错")
    } catch let error as DeviceError {
        #expect(error.code == .UNSUPPORTED)
    } catch {
        Issue.record("错误类型不对")
    }
    #expect(throws: DeviceError.self) { try actions.logStream() }
}
