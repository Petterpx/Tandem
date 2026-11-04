import DeviceCore
import Foundation

public struct SimulatorDevice: Identifiable, Equatable, Sendable {
    public var id: String { udid }
    public let udid: String
    public let name: String
    public let runtime: String
    public let isBooted: Bool

    public init(udid: String, name: String, runtime: String, isBooted: Bool) {
        self.udid = udid
        self.name = name
        self.runtime = runtime
        self.isBooted = isBooted
    }
}

public struct SimctlClient: Sendable {
    private let runner: any ProcessRunner
    private let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")

    public init(runner: any ProcessRunner = SystemProcessRunner()) { self.runner = runner }

    public func availableDevices() async throws -> [SimulatorDevice] {
        try Self.parseDevices(await command(["list", "devices", "available", "--json"]))
    }

    public func boot(_ udid: String) async throws {
        try Self.validate(udid)
        // A booted device may race discovery; bootstatus is authoritative in that case.
        let result = try await runner.run(xcrun, ["simctl", "boot", udid], timeout: .seconds(30))
        if result.exitCode != 0 {
            let devices = try await availableDevices()
            guard devices.contains(where: { $0.udid.caseInsensitiveCompare(udid) == .orderedSame && $0.isBooted }) else {
                throw Self.failure(result)
            }
        }
        _ = try await command(["bootstatus", udid, "-b"], timeout: .seconds(180))
    }

    public func screenshot(_ udid: String) async throws -> Data {
        try Self.validate(udid)
        // Some Xcode versions create a file literally named "-" instead of sending
        // screenshot bytes to stdout. Always give simctl an explicit private file.
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("tandem-screenshot-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: directory) }
        let file = directory.appendingPathComponent("screenshot.png")
        _ = try await command(["io", udid, "screenshot", "--type=png", file.path])
        try Task.checkCancellation()
        guard let data = try? Data(contentsOf: file) else {
            throw DeviceError(code: .CONNECTION_FAILED, message: "simctl 未生成可读取的 PNG 截图")
        }
        let signature: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
        guard data.count > signature.count, data.starts(with: signature) else {
            throw DeviceError(code: .CONNECTION_FAILED, message: "simctl 截图为空或不是 PNG 格式")
        }
        return data
    }

    public func openURL(_ url: String, on udid: String) async throws {
        try Self.validate(udid)
        guard let parsed = URL(string: url), parsed.scheme != nil, !url.contains("\0") else {
            throw DeviceError(code: .INVALID_ARGUMENT, message: "链接必须包含有效协议")
        }
        _ = try await command(["openurl", udid, url])
    }

    static func validate(_ udid: String) throws {
        guard UUID(uuidString: udid) != nil else {
            throw DeviceError(code: .INVALID_ARGUMENT, message: "模拟器必须使用明确的 UDID，不能使用 booted 别名")
        }
    }

    private func command(_ arguments: [String], timeout: Duration = .seconds(30)) async throws -> Data {
        do {
            let result = try await runner.run(xcrun, ["simctl"] + arguments, timeout: timeout)
            guard result.exitCode == 0 else { throw Self.failure(result) }
            return result.stdout
        } catch let error as DeviceError { throw error }
        catch { throw DeviceError(code: .CONNECTION_FAILED, message: "无法运行 Xcode simctl：\(error.localizedDescription)", suggestion: "请安装 Xcode 并在 xcode-select 中选中完整 Xcode") }
    }

    private static func failure(_ result: ProcessResult) -> DeviceError {
        let detail = String(decoding: result.stderr.prefix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return DeviceError(code: .CONNECTION_FAILED, message: "simctl 失败：\(detail)", suggestion: "请确认已安装 Xcode 和 iOS 模拟器运行时，并已通过 xcode-select 选中完整 Xcode")
    }

    static func parseDevices(_ data: Data) throws -> [SimulatorDevice] {
        struct Listing: Decodable { let devices: [String: [Entry]] }
        struct Entry: Decodable { let udid: String?; let name: String?; let state: String?; let isAvailable: Bool? }
        do {
            let listing = try JSONDecoder().decode(Listing.self, from: data)
            return listing.devices.flatMap { runtime, entries -> [SimulatorDevice] in
                guard runtime.contains(".SimRuntime.iOS-") || runtime.contains(".SimRuntime.iPadOS-") else { return [] }
                return entries.compactMap { entry in
                    guard entry.isAvailable == true, let udid = entry.udid, UUID(uuidString: udid) != nil,
                          let name = entry.name, !name.isEmpty else { return nil }
                    return SimulatorDevice(udid: udid.uppercased(), name: name, runtime: runtime, isBooted: entry.state == "Booted")
                }
            }.sorted { $0.udid < $1.udid }
        } catch { throw DeviceError(code: .CONNECTION_FAILED, message: "无法解析 simctl 设备列表：\(error.localizedDescription)") }
    }
}
