import Foundation
import DeviceCore

public struct PairingCredentials: Equatable, Sendable {
    public var name: String
    public var password: String

    public init(name: String, password: String) {
        self.name = name
        self.password = password
    }

    public static func generate<G: RandomNumberGenerator>(using g: inout G) -> Self {
        let alphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let digits = Array("0123456789")
        let suffix = String((0..<10).map { _ in alphabet.randomElement(using: &g)! })
        let password = String((0..<12).map { _ in digits.randomElement(using: &g)! })
        return Self(name: "studio-" + suffix, password: password)
    }

    public var qrPayload: String { "WIFI:T:ADB;S:\(name);P:\(password);;" }
}

public enum WirelessStep: Equatable, Sendable {
    case waitingForScan, pairing, connecting, connected(serial: String)
}

public actor WirelessConnector {
    private let adb: AdbClient
    private let pollInterval: Duration
    private let clock = ContinuousClock()

    public init(adb: AdbClient, pollInterval: Duration = .seconds(1)) {
        self.adb = adb
        self.pollInterval = pollInterval
    }

    public func pairWithQR(
        _ creds: PairingCredentials,
        timeout: Duration = .seconds(120),
        progress: @Sendable (WirelessStep) -> Void
    ) async throws -> String {
        progress(.waitingForScan)
        let deadline = clock.now.advanced(by: timeout)
        var pairing: MdnsService?
        while pairing == nil {
            let services = try await mdnsServices()
            pairing = services.first { $0.kind == .pairing && $0.instance == creds.name }
            if pairing != nil { break }
            guard clock.now < deadline else { throw DeviceError.timeout("等待扫码") }
            try await Task.sleep(for: pollInterval)
        }
        let service = pairing!
        progress(.pairing)
        try await pair("\(service.host):\(service.port)", creds.password)
        return try await connectAfterPairing(host: service.host, progress: progress)
    }

    public func pairWithCode(
        hostPort: String,
        code: String,
        progress: @Sendable (WirelessStep) -> Void
    ) async throws -> String {
        progress(.pairing)
        try await pair(hostPort, code)
        let host = hostPort.lastIndex(of: ":").map { String(hostPort[..<$0]) } ?? hostPort
        return try await connectAfterPairing(host: host, progress: progress)
    }

    public func switchToWireless(serial: String) async throws -> String {
        let output = try await adb.shell(serial, "ip -f inet addr show wlan0")
        guard let ip = Self.parseWlanIPv4(output) else {
            throw DeviceError.connectionFailed("手机未连接 Wi-Fi")
        }
        _ = try await adb.run(["tcpip", "5555"], serial: serial)
        try await Task.sleep(for: .seconds(1))
        let target = "\(ip):5555"
        var lastOutput = ""
        for attempt in 0..<3 {
            if attempt > 0 { try await Task.sleep(for: .seconds(1)) }
            let result = try await adb.run(["connect", target])
            lastOutput = Self.text(result)
            if result.stdoutString.contains("connected to") { return target }
        }
        throw DeviceError.connectionFailed(lastOutput)
    }

    public static func parseWlanIPv4(_ text: String) -> String? {
        text.firstMatch(of: /inet\s+(\d{1,3}(?:\.\d{1,3}){3})\//).map { String($0.1) }
    }

    // MARK: - 内部

    private func mdnsServices() async throws -> [MdnsService] {
        MdnsParser.parse(try await adb.run(["mdns", "services"]).stdoutString)
    }

    private func pair(_ hostPort: String, _ code: String) async throws {
        let result = try await adb.run(["pair", hostPort, code])
        guard result.stdoutString.contains("Successfully paired") else {
            throw DeviceError.connectionFailed(Self.text(result))
        }
    }

    private func connectAfterPairing(host: String, progress: @Sendable (WirelessStep) -> Void) async throws -> String {
        progress(.connecting)
        let deadline = clock.now.advanced(by: .seconds(30))
        var service: MdnsService?
        while service == nil {
            service = try await mdnsServices().first { $0.kind == .connect && $0.host == host }
            if service != nil { break }
            guard clock.now < deadline else { throw DeviceError.timeout("等待设备无线调试服务") }
            try await Task.sleep(for: pollInterval)
        }
        let target = "\(service!.host):\(service!.port)"
        let result = try await adb.run(["connect", target])
        guard result.stdoutString.contains("connected to") else {
            throw DeviceError.connectionFailed(Self.text(result))
        }
        progress(.connected(serial: target))
        return target
    }

    /// adb 的失败信息通常在 stdout；为空时回退到 stderr。
    private static func text(_ result: ProcessResult) -> String {
        let out = result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !out.isEmpty { return out }
        return String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
