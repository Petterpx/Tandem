import AndroidDriver
import DeviceCore
import Foundation

/// 各平台独立初始化；Android 的依赖错误不阻断模拟器发现。
struct AppDriverSetup: Sendable {
    struct Android: Sendable {
        var adb: Adb
        var client: AdbClient
        var driver: any DeviceDriver
    }

    var drivers: [any DeviceDriver]
    var android: Android?
    var androidError: DeviceError?

    static func load(
        simulator: any DeviceDriver,
        android loadAndroid: @Sendable () async throws -> Android
    ) async -> Self {
        do {
            let android = try await loadAndroid()
            return Self(drivers: [android.driver, simulator], android: android)
        } catch {
            return Self(drivers: [simulator], androidError: error as? DeviceError ?? .adbNotFound())
        }
    }
}
