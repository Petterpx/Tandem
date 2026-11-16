import DeviceCore
import Foundation

/// Short-lived Apple CLI operations, independent from the running USB mirror.
/// Only directory reads are cached/coalesced. Launch is always dispatched once.
actor IOSPhysicalAppLauncher {
    static let shared = IOSPhysicalAppLauncher()
    private let runner: any ProcessRunner
    private let cacheLifetime: Duration
    private let clock = ContinuousClock()
    private var cached: [String: (expires: ContinuousClock.Instant, apps: [InstalledApp])] = [:]
    private struct Flight {
        let id = UUID()
        let task: Task<[InstalledApp], any Error>
    }
    private var flights: [String: Flight] = [:]

    init(runner: any ProcessRunner = SystemProcessRunner(), cacheLifetime: Duration = .seconds(60)) {
        self.runner = runner
        self.cacheLifetime = cacheLifetime
    }

    func installedApps(on serial: String) async throws -> [InstalledApp] {
        try Self.validateSerial(serial)
        try Task.checkCancellation()
        if let entry = cached[serial], entry.expires > clock.now { return entry.apps }
        let flight: Flight
        if let pending = flights[serial] { flight = pending }
        else {
            let runner = runner
            flight = Flight(task: Task {
                let data = try await Self.command(runner, serial: serial, operation: .list)
                return try Self.parseApps(data)
            })
            flights[serial] = flight
        }
        do {
            let apps = try await flight.task.value
            if flights[serial]?.id == flight.id {
                cached[serial] = (clock.now.advanced(by: cacheLifetime), apps)
                flights.removeValue(forKey: serial)
            }
            try Task.checkCancellation()
            return apps
        } catch {
            if flights[serial]?.id == flight.id { flights.removeValue(forKey: serial) }
            throw error
        }
    }

    func launch(_ bundleID: String, on serial: String) async throws {
        try Self.validateSerial(serial)
        try Self.validateBundleID(bundleID)
        try Task.checkCancellation()
        let data = try await Self.command(runner, serial: serial, operation: .launch(bundleID))
        guard let envelope = try? JSONDecoder().decode(Outcome.self, from: data), envelope.info.outcome == "success" else {
            throw DeviceError(code: .CONNECTION_FAILED, message: "iPhone 应用启动未获成功确认；未重试")
        }
    }

    private enum Operation { case list, launch(String) }
    private struct Outcome: Decodable {
        struct Info: Decodable { let outcome: String }
        let info: Info
    }

    private static func command(_ runner: any ProcessRunner, serial: String, operation: Operation) async throws -> Data {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("tandem-apps-\(UUID().uuidString)", isDirectory: true)
        do { try manager.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw DeviceError(code: .CONNECTION_FAILED, message: "无法创建 iPhone 应用操作临时目录") }
        defer { try? manager.removeItem(at: directory) }
        let file = directory.appendingPathComponent("result.json")
        let args: [String]
        let isLaunch: Bool
        switch operation {
        case .list:
            args = ["devicectl", "device", "info", "apps", "--include-all-apps"]
            isLaunch = false
        case .launch:
            args = ["devicectl", "device", "process", "launch"]
            isLaunch = true
        }
        do {
            var command = args + ["--device", serial, "--timeout", "12", "--quiet", "--json-output", file.path]
            if case let .launch(bundleID) = operation { command.append(bundleID) }
            let result = try await runner.run(URL(fileURLWithPath: "/usr/bin/xcrun"), command, timeout: .seconds(15))
            try Task.checkCancellation()
            guard result.exitCode == 0 else {
                throw DeviceError(code: .CONNECTION_FAILED, message: isLaunch ? "iPhone 应用启动失败；设备执行状态未知，未重试" : "无法读取 iPhone 应用目录；请确认设备已解锁、受信任且 Xcode 可用")
            }
            // Never include the CLI's stderr or raw JSON in errors.
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024,
                  let data = try? Data(contentsOf: file) else {
                throw DeviceError(code: .CONNECTION_FAILED, message: "devicectl 未生成有效的应用操作结果")
            }
            return data
        } catch is CancellationError { throw CancellationError() }
        catch let error as DeviceError {
            if error.code == .TIMEOUT {
                throw DeviceError(code: .TIMEOUT, message: isLaunch ? "iPhone 应用启动超时；设备执行状态未知，未重试" : "读取 iPhone 应用目录超时")
            }
            throw error
        } catch {
            throw DeviceError(code: .CONNECTION_FAILED, message: "无法运行 Xcode devicectl；请检查 Xcode 和设备连接")
        }
    }

    static func validateBundleID(_ bundleID: String) throws {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-".utf8)
        guard !bundleID.isEmpty, bundleID.utf8.count <= 255, bundleID.contains("."),
              bundleID.first != "-", bundleID.first != ".", bundleID.last != ".",
              !bundleID.contains(".."), bundleID.utf8.allSatisfy(allowed.contains) else {
            throw DeviceError(code: .INVALID_ARGUMENT, message: "应用必须使用有效的 bundle identifier")
        }
    }

    private static func validateSerial(_ serial: String) throws {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-".utf8)
        guard !serial.isEmpty, serial.utf8.count <= 64, serial.first != "-", serial.utf8.allSatisfy(allowed.contains) else {
            throw DeviceError(code: .INVALID_ARGUMENT, message: "iPhone 应用操作须使用明确的设备 UDID")
        }
    }

    static func parseApps(_ data: Data) throws -> [InstalledApp] {
        struct Listing: Decodable {
            struct Result: Decodable {
                struct App: Decodable { let name: String?; let bundleIdentifier: String? }
                let apps: [App]
            }
            let info: Outcome.Info
            let result: Result
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data), listing.info.outcome == "success" else {
            throw DeviceError(code: .CONNECTION_FAILED, message: "无法解析 iPhone 应用目录")
        }
        var seen = Set<String>()
        return listing.result.apps.compactMap { app in
            guard let bundleID = app.bundleIdentifier, (try? validateBundleID(bundleID)) != nil, seen.insert(bundleID).inserted else { return nil }
            let name = app.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            return InstalledApp(name: name.flatMap { $0.isEmpty ? nil : $0 } ?? bundleID, bundleID: bundleID)
        }.sorted { ($0.name.lowercased(), $0.bundleID) < ($1.name.lowercased(), $1.bundleID) }
    }
}
