import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct AppModelTests {
    private func dev(_ id: String) -> DeviceInfo {
        DeviceInfo(serial: id, platform: .android, name: id, state: .connected, connection: .usb)
    }

    private func model(backgroundLaunch: Bool) -> (AppModel, opened: () -> Int) {
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!, backgroundLaunch: backgroundLaunch)
        model.autoOpenOnConnect = true
        var count = 0
        model.requestOpenWorkspace = { count += 1 }
        return (model, { count })
    }

    @Test func backgroundLaunchDoesNotAutoOpenUntilUserOpens() async {
        let (model, opened) = model(backgroundLaunch: true)
        await model.devicesUpdated([dev("a")])
        #expect(opened() == 0 && model.selectedID == nil)
        model.endBackgroundLaunch()
        // 启动时就在的设备之后也不再自动打开
        await model.devicesUpdated([dev("a")])
        #expect(opened() == 0)
        // 用户打开过工作台之后新插入的设备照常自动打开
        await model.devicesUpdated([dev("a"), dev("b")])
        #expect(opened() == 1)
    }

    @Test func normalLaunchAutoOpens() async {
        let (model, opened) = model(backgroundLaunch: false)
        await model.devicesUpdated([dev("a")])
        #expect(opened() == 1)
    }
}
