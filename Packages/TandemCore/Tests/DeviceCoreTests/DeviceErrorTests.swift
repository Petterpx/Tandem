import Testing
@testable import DeviceCore

@Test func adbNotFoundHasInstallHint() {
    let e = DeviceError.adbNotFound()
    #expect(e.code == .ADB_NOT_FOUND)
    #expect(e.suggestion?.contains("brew install --cask android-platform-tools") == true)
}

@Test func codeRawValuesMatchSpec() {
    #expect(DeviceError.Code.INJECT_PERMISSION_DENIED.rawValue == "INJECT_PERMISSION_DENIED")
}
