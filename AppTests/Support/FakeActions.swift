import DeviceCore
import Foundation

/// 测试用的设备操作替身：返回固定 PNG 或抛出指定错误；UI 树每次读取时由 treeProvider 生成。
struct FakeActions: DeviceActions {
    var result: Result<Data, DeviceError> = .success(Data([0x89, 0x50, 0x4E, 0x47]))
    /// 每次 uiTree() 调用时求值：可随调用次数变化或抛错，默认返回空树。
    var treeProvider: @Sendable () throws -> UITree = { UITree(screen: CGSize(width: 1080, height: 2400), elements: []) }
    func screenshot() async throws -> Data { try result.get() }
    func uiTree() async throws -> UITree { try treeProvider() }
}
