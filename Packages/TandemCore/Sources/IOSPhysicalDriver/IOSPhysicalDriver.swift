import DeviceCore
import Foundation
import MediaKit

public struct IOSPhysicalDriver: DeviceDriver {
    private let helperURL: URL?
    private let cache = USBSessionCache()
    public var availabilityError: DeviceError? { Self.unavailabilityReason(helperURL: helperURL) }
    public var capabilities: Set<Capability> { availabilityError == nil ? [.mirror, .touch, .keys, .text, .screenshot, .record, .appLaunch] : [] }
    public init(helperURL: URL? = nil) {
        self.helperURL = helperURL ?? Bundle.main.url(forAuxiliaryExecutable: "tandem-ios-usb")
    }
    public static func unavailabilityReason(helperURL: URL?) -> DeviceError? {
        guard let helperURL, FileManager.default.isExecutableFile(atPath: helperURL.path) else {
            return .unsupported("未找到可执行的 tandem-ios-usb helper")
        }
        return nil
    }
    public func deviceSnapshots() -> AsyncStream<[DeviceInfo]> {
        let (stream, output) = AsyncStream<[DeviceInfo]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = Task {
            var previous: [DeviceInfo]?
            while !Task.isCancelled {
                let snapshot: [DeviceInfo]
                do {
                    guard availabilityError == nil, let helperURL else { throw DeviceError.unsupported("USB helper 不可用") }
                    let data = try await Self.list(helperURL)
                    snapshot = try Self.devices(data, capabilities: capabilities)
                } catch { snapshot = [] }
                if Task.isCancelled { break }
                if previous != snapshot { previous = snapshot; output.yield(snapshot) }
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
            output.finish()
        }
        output.onTermination = { _ in task.cancel() }
        return stream
    }
    static func devices(_ data: Data, capabilities: Set<Capability>) throws -> [DeviceInfo] {
        struct Entry: Decodable { let udid: String; let connection: String }
        var seen = Set<String>()
        return try JSONDecoder().decode([Entry].self, from: data).filter {
            $0.connection == "usb" && !$0.udid.isEmpty && seen.insert($0.udid).inserted
        }.map { .init(serial: $0.udid, platform: .ios, name: "iPhone USB", state: .connected, connection: .usb,
                      hardwareSerial: $0.udid, capabilities: capabilities) }
    }
    private static func list(_ url: URL) async throws -> Data {
        try await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = url
            process.arguments = ["--list"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(5)) {
                if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw protocolError("USB 设备发现失败") }
            return data
        }.value
    }
    public func makeSession(for device: DeviceInfo) -> any DeviceSession { session(device) }
    public func makeActions(for device: DeviceInfo) -> any DeviceActions { IOSPhysicalActions(session: session(device), serial: device.serial) }
    private func session(_ device: DeviceInfo) -> IOSPhysicalSession {
        cache.session(device, helperURL: helperURL)
    }
}

private final class USBSessionCache: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [String: IOSPhysicalSession] = [:]
    func session(_ device: DeviceInfo, helperURL: URL?) -> IOSPhysicalSession {
        lock.withLock {
            if let session = sessions[device.serial] { session.updateDevice(device); return session }
            let session = IOSPhysicalSession(device: device, helperURL: helperURL)
            sessions[device.serial] = session
            return session
        }
    }
}

public struct IOSPhysicalActions: DeviceActions {
    private let session: IOSPhysicalSession
    private let serial: String?
    public init(session: IOSPhysicalSession, serial: String? = nil) { self.session = session; self.serial = serial }
    private func deviceSerial() throws -> String {
        guard let serial = serial ?? session.activeSerial else { throw DeviceError(code: .DEVICE_NOT_FOUND, message: "未指定 iPhone 设备") }
        return serial
    }
    public func installedApps() async throws -> [InstalledApp] {
        try await IOSPhysicalAppLauncher.shared.installedApps(on: deviceSerial())
    }
    public func launchApp(_ package: String) async throws {
        try await IOSPhysicalAppLauncher.shared.launch(package, on: deviceSerial())
    }
    public func screenshot() async throws -> Data {
        throw DeviceError.unsupported("iPhone USB 实验驱动暂不支持系统原图，请使用普通投屏截图")
    }
    public func uiTree() async throws -> UITree { throw DeviceError.unsupported("iPhone USB 暂不支持 UI 树，请使用截图和坐标操作") }
}
