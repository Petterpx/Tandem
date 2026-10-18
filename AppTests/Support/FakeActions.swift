import DeviceCore
import Foundation

/// 测试用的设备操作替身：返回固定 PNG 或抛出指定错误。
struct FakeActions: DeviceActions {
    var result: Result<Data, DeviceError> = .success(Data([0x89, 0x50, 0x4E, 0x47]))
    func screenshot() async throws -> Data { try result.get() }
}
