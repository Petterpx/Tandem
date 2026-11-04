import Testing
import DeviceCore
@testable import Tandem

@MainActor
@Suite struct SidebarTests {
    private let usbConnectedDevice = DeviceInfo(serial: "s1", platform: .android, name: "Pixel 8", state: .connected, connection: .usb)

    @Test func windowTitle() {
        #expect(WorkspaceText.windowTitle(deviceName: "Pixel 8") == "Tandem · Pixel 8" && WorkspaceText.windowTitle(deviceName: nil) == "Tandem")
    }

    @Test func rowDotOpacityAndSubtitle() {
        #expect(DeviceRowView.dotColor(.connected) == Theme.success && DeviceRowView.dotColor(.unauthorized) == Theme.dotOff)
        #expect(DeviceRowView.opacity(.unauthorized) == 0.55 && DeviceRowView.opacity(.offline) == 1)
        #expect(DeviceRowView.subtitle(usbConnectedDevice) == "USB · 已连接")
    }

    @Test func simulatorRowShowsLocalConnection() {
        let device = DeviceInfo(serial: "sim-1", platform: .ios, name: "iPhone", state: .connected, connection: .simulator)
        #expect(DeviceRowView.subtitle(device) == "模拟器 · 已连接")
    }
}
