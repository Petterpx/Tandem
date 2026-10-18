public actor DeviceManager {
    private let drivers: [any DeviceDriver]
    private var snapshots: [[DeviceInfo]]
    private var merged: [DeviceInfo]?
    private var subscribers: [Int: AsyncStream<[DeviceInfo]>.Continuation] = [:]
    private var nextSubscriberID = 0
    private var consumers: [Task<Void, Never>] = []
    private var sessions: [String: any DeviceSession] = [:]
    private var started = false

    public init(drivers: [any DeviceDriver]) {
        self.drivers = drivers
        self.snapshots = Array(repeating: [], count: drivers.count)
    }

    deinit {
        for task in consumers { task.cancel() }
    }

    /// 合并后的列表，任一驱动更新时推送；新订阅者会立即收到当前列表（若已有）。
    public func devices() -> AsyncStream<[DeviceInfo]> {
        startIfNeeded()
        let (stream, continuation) = AsyncStream<[DeviceInfo]>.makeStream()
        let id = nextSubscriberID
        nextSubscriberID += 1
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        if let merged { continuation.yield(merged) }
        return stream
    }

    public func session(for id: String) -> (any DeviceSession)? {
        guard let merged, let device = merged.first(where: { $0.id == id }) else { return nil }
        if let cached = sessions[id] { return cached }
        for (index, snapshot) in snapshots.enumerated() where snapshot.contains(where: { $0.id == id }) {
            let session = drivers[index].makeSession(for: device)
            sessions[id] = session
            return session
        }
        return nil
    }

    public static func merge(_ snapshots: [[DeviceInfo]]) -> [DeviceInfo] {
        var result: [DeviceInfo] = []
        var connectedBySerial: [String: Int] = [:]
        for device in snapshots.joined() {
            guard device.state == .connected, let serial = device.hardwareSerial else {
                result.append(device)
                continue
            }
            if let index = connectedBySerial[serial] {
                if device.connection == .usb && result[index].connection != .usb {
                    result[index] = device
                }
            } else {
                connectedBySerial[serial] = result.count
                result.append(device)
            }
        }
        return result.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    private func startIfNeeded() {
        guard !started else { return }
        started = true
        for (index, driver) in drivers.enumerated() {
            let stream = driver.deviceSnapshots()
            consumers.append(Task { [weak self] in
                for await snapshot in stream {
                    await self?.update(index: index, snapshot: snapshot)
                }
            })
        }
    }

    private func update(index: Int, snapshot: [DeviceInfo]) {
        snapshots[index] = snapshot
        let list = Self.merge(snapshots)
        merged = list
        for continuation in subscribers.values { continuation.yield(list) }
    }

    private func removeSubscriber(_ id: Int) {
        subscribers[id] = nil
    }
}
