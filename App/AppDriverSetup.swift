import AndroidDriver
import DeviceCore
import Foundation

/// 各平台独立初始化；Android 的依赖错误不阻断其他平台发现。
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
        physical: (any DeviceDriver)? = nil,
        android loadAndroid: @Sendable () async throws -> Android
    ) async -> Self {
        let otherDrivers = [simulator] + (physical.map { [$0] } ?? [])
        do {
            let android = try await loadAndroid()
            return Self(drivers: [android.driver] + otherDrivers, android: android)
        } catch {
            return Self(drivers: otherDrivers, androidError: error as? DeviceError ?? .adbNotFound())
        }
    }
}
