import Testing
import DeviceCore

@Suite struct DeviceKeyTests {
    @Test func iosRejectsAndroidNavigationAndHardwareKeys() {
        for key: DeviceKey in [.back, .recents, .power, .volumeUp, .volumeDown] {
            #expect(!key.isSupported(on: .ios))
            #expect(key.isSupported(on: .android))
        }
    }

    @Test func iosAllowsHomeAndKeyboardEditing() {
        for key: DeviceKey in [.home, .enter, .delete, .forwardDelete, .tab, .up, .down, .left, .right] {
            #expect(key.isSupported(on: .ios))
            #expect(key.isSupported(on: .android))
        }
    }
}
