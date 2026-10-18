import DeviceCore
import Foundation

/// 测试用的设备操作替身：返回固定 PNG 或抛出指定错误；UI 树每次读取时由 treeProvider 生成。
struct FakeActions: DeviceActions {
    var result: Result<Data, DeviceError> = .success(Data([0x89, 0x50, 0x4E, 0x47]))
    /// 设置后截图改由它产生（可挂起或延迟，模拟截图很慢）；默认 nil，返回 result。
    var screenshotProvider: (@Sendable () async throws -> Data)?
    /// 每次 uiTree() 调用时求值：可随调用次数变化或抛错，默认返回空树。
    var treeProvider: @Sendable () throws -> UITree = { UITree(screen: CGSize(width: 1080, height: 2400), elements: []) }
    func screenshot() async throws -> Data {
        if let screenshotProvider { return try await screenshotProvider() }
        return try result.get()
    }
    func uiTree() async throws -> UITree { try treeProvider() }
}
