import Foundation
import DeviceCore

public final class AndroidDriver: DeviceDriver {
    private let adb: AdbClient
    private let runner: any ProcessRunner
    private let serverJar: URL
    private let restartDelay: Duration
    private let serials = SerialCache()

    public init(adb: AdbClient, runner: any ProcessRunner, serverJar: URL, restartDelay: Duration = .seconds(2)) {
        self.adb = adb
        self.runner = runner
        self.serverJar = serverJar
        self.restartDelay = restartDelay
    }

    public func deviceSnapshots() -> AsyncStream<[DeviceInfo]> {
        let (stream, continuation) = AsyncStream<[DeviceInfo]>.makeStream()
        let task = Task { [adb, runner, restartDelay, serials] in
            while !Task.isCancelled {
                if let (bytes, process) = try? runner.streamBytes(adb.adb.url, ["track-devices", "-l"]) {
                    var decoder = TrackDevicesDecoder()
                    await withTaskCancellationHandler {
                        for await chunk in bytes {
                            for entries in decoder.append(chunk) {
                                // 只为持续处于 connected 的 serial 保留缓存：离开列表或掉线后，同一个 ip:port
                                // 可能换成另一台手机。
                                serials.retain(Set(entries.filter { DeviceListParser.deviceState($0.state) == .connected }.map(\.serial)))
                                var devices: [DeviceInfo] = []
                                for entry in entries {
                                    devices.append(await Self.info(for: entry, adb: adb, serials: serials))
                                }
                                continuation.yield(devices)
                            }
                        }
                    } onCancel: {
                        process.terminate()
                    }
                    process.terminate()
                }
                // 进程意外退出（或无法启动）：延迟后重启。
                try? await Task.sleep(for: restartDelay)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func makeSession(for device: DeviceInfo) -> any DeviceSession {
        AndroidSession(device: device,
                       launcher: AdbScrcpyLauncher(adb: adb, runner: runner, serverJar: serverJar),
                       makeDecoder: { H264Decoder(onFrame: $0) })
    }

    public func makeActions(for device: DeviceInfo) -> any DeviceActions {
        AndroidActions(serial: device.serial, adb: adb)
    }

    private static func info(for entry: AdbDeviceEntry, adb: AdbClient, serials: SerialCache) async -> DeviceInfo {
        let state = DeviceListParser.deviceState(entry.state)
        var hardwareSerial: String?
        if state == .connected {
            if let cached = serials.value(for: entry.serial) {
                hardwareSerial = cached
            } else {
                let raw = (try? await adb.getprop(entry.serial, "ro.serialno"))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                hardwareSerial = (raw?.isEmpty ?? true) ? nil : raw
                // 读取失败不缓存，下一次快照重试。
                if let hardwareSerial { serials.store(hardwareSerial, for: entry.serial) }
            }
        }
        return DeviceInfo(
            serial: entry.serial,
            platform: .android,
            name: entry.model.map { $0.replacingOccurrences(of: "_", with: " ") } ?? entry.serial,
            state: state,
            connection: DeviceListParser.connectionKind(serial: entry.serial),
            hardwareSerial: hardwareSerial,
            capabilities: [.mirror, .touch, .keys, .text, .clipboard, .screenshot, .record]
        )
    }
}

/// adb serial → ro.serialno。
private final class SerialCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    func value(for key: String) -> String? {
        lock.withLock { cache[key] }
    }
    func store(_ value: String, for key: String) {
        lock.withLock { cache[key] = value }
    }
    /// 丢弃不在 keys 里的条目。
    func retain(_ keys: Set<String>) {
        lock.withLock { cache = cache.filter { keys.contains($0.key) } }
    }
}
