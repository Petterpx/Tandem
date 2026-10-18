import SwiftUI
import DeviceCore
import AndroidDriver

@main
struct MagicDevXApp: App {
    var body: some Scene {
        MenuBarExtra("MagicDevX", systemImage: "iphone.gen3") {
            Text("暂无设备")
            Divider()
            Button("退出") { NSApplication.shared.terminate(nil) }
        }
    }
}
