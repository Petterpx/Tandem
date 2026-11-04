import DeviceCore
import Foundation

public struct IOSSimulatorDriver: DeviceDriver {
    private let helperURL: URL?
    private let client: SimctlClient
    private let pollInterval: Duration
    public var availabilityError: DeviceError? { Self.unavailabilityReason(helperURL: helperURL) }
    public var capabilities: Set<Capability> {
        availabilityError == nil ? [.mirror, .touch, .keys, .text, .clipboard, .screenshot, .record, .openURL] : []
    }

    public init(helperURL: URL? = nil, client: SimctlClient = SimctlClient()) {
        self.init(helperURL: helperURL, client: client, pollInterval: .seconds(2))
    }

    init(helperURL: URL?, client: SimctlClient, pollInterval: Duration) {
        self.pollInterval = pollInterval
        self.helperURL = helperURL ?? Bundle.main.url(forAuxiliaryExecutable: "tandem-simulator")
        self.client = client
    }

    public static func unavailabilityReason(helperURL: URL?) -> DeviceError? {
        #if !arch(arm64)
        return .unsupported("iOS 模拟器控制需要 Apple Silicon Mac")
        #else
        guard #available(macOS 15, *) else { return .unsupported("iOS 模拟器控制需要 macOS 15 或更新系统") }
        guard let helperURL, FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return DeviceError(code: .UNSUPPORTED, message: "未找到可执行的 tandem-simulator helper", suggestion: "请构建 Packages/SimulatorHelper 并将 tandem-simulator 随 App 打包；还需要安装完整 Xcode 和 iOS 模拟器运行时")
        }
        return nil
        #endif
    }

    public func deviceSnapshots() -> AsyncStream<[DeviceInfo]> {
        let (stream, output) = AsyncStream<[DeviceInfo]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            var previous: [DeviceInfo]?
            while !Task.isCancelled {
                let snapshot: [DeviceInfo]
                do {
                    let devices = try await client.availableDevices()
                    guard !Task.isCancelled else { break }
                    snapshot = devices.filter(\.isBooted).map {
                        DeviceInfo(serial: $0.udid, platform: .ios, name: $0.name, state: .connected,
                                   connection: .simulator, hardwareSerial: $0.udid, capabilities: capabilities)
                    }
                } catch {
                    guard !Task.isCancelled else { break }
                    // A missing Xcode installation must not stop discovery from other drivers.
                    snapshot = []
                }
                if previous != snapshot {
                    previous = snapshot
                    output.yield(snapshot)
                }
                do { try await Task.sleep(for: pollInterval) } catch { break }
            }
            output.finish()
        }
        output.onTermination = { _ in task.cancel() }
        return stream
    }

    public func makeSession(for device: DeviceInfo) -> any DeviceSession {
        IOSSimulatorSession(device: device, helperURL: helperURL)
    }
    public func makeActions(for device: DeviceInfo) -> any DeviceActions {
        IOSSimulatorActions(udid: device.serial, client: client)
    }
}

public struct IOSSimulatorActions: DeviceActions {
    private let udid: String
    private let client: SimctlClient
    public init(udid: String, client: SimctlClient = SimctlClient()) { self.udid = udid; self.client = client }
    public func screenshot() async throws -> Data { try await client.screenshot(udid) }
    public func openURL(_ url: String) async throws { try await client.openURL(url, on: udid) }
    public func uiTree() async throws -> UITree {
        throw DeviceError.unsupported("iOS 模拟器暂不支持 UI 树或按文字/元素点击，请使用截图和坐标操作")
    }
}
