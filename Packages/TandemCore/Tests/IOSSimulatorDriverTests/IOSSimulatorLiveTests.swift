import CoreVideo
import DeviceCore
import Foundation
import Testing
@testable import IOSSimulatorDriver

/// 手动触发：指定已启动的测试模拟器与已构建 helper，不操作模拟器内的用户应用。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["TANDEM_TEST_SIMULATOR"] != nil
                && ProcessInfo.processInfo.environment["TANDEM_SIMULATOR_HELPER"] != nil))
struct IOSSimulatorLiveTests {
    @Test func nativeHelperProducesUsableFramesAndShutsDown() async throws {
        let env = ProcessInfo.processInfo.environment
        let udid = try #require(env["TANDEM_TEST_SIMULATOR"])
        let helper = URL(fileURLWithPath: try #require(env["TANDEM_SIMULATOR_HELPER"]))
        let client = SimctlClient()
        #expect(try await client.availableDevices().contains { $0.udid == udid && $0.isBooted })
        let device = DeviceInfo(serial: udid, platform: .ios, name: "Integration Simulator",
                                state: .connected, connection: .simulator)
        let session = IOSSimulatorSession(device: device, helperURL: helper)
        await session.start()
        do {
            let size = try await withThrowingTaskGroup(of: (Int, Int).self) { group in
                group.addTask {
                    for await event in session.events {
                        if case let .state(.running(width, height)) = event { return (width, height) }
                        if case let .state(.failed(error)) = event { throw error }
                    }
                    throw DeviceError(code: .CONNECTION_FAILED, message: "会话事件提前结束")
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(25))
                    throw DeviceError.timeout("原生模拟器测试")
                }
                defer { group.cancelAll() }
                return try await #require(group.next())
            }
            let frame = try #require(session.latestFrame())
            #expect(CVPixelBufferGetWidth(frame.pixelBuffer) == size.0)
            #expect(CVPixelBufferGetHeight(frame.pixelBuffer) == size.1)
            #expect(CVPixelBufferGetIOSurface(frame.pixelBuffer) != nil)
            _ = try await session.getClipboard()
            let png = try await client.screenshot(udid)
            #expect(png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]))
            await session.stop()
            #expect(session.latestFrame() == nil)
            #expect(session.activeSerial == nil)
        } catch {
            await session.stop()
            throw error
        }
    }
}
