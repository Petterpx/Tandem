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

    /// 按逻辑 id 取会话；同一 id 始终是同一个会话实例（跨断开重连、跨 USB / Wi-Fi 切换）。
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

    /// 每次按合并列表里该 id 当前的 DeviceInfo 新建，USB / Wi-Fi 切换后自动用新 serial；
    /// id 不在列表或不是 connected 时返回 nil。
    public func actions(for id: String) -> (any DeviceActions)? {
        guard let merged, let device = merged.first(where: { $0.id == id }), device.state == .connected else { return nil }
        for (index, snapshot) in snapshots.enumerated() where snapshot.contains(where: { $0.serial == device.serial && $0.id == id }) {
            return drivers[index].makeActions(for: device)
        }
        return nil
    }

    /// 每个逻辑 id 一条：优先 connected，其次 USB。
    public static func merge(_ snapshots: [[DeviceInfo]]) -> [DeviceInfo] {
        var result: [DeviceInfo] = []
        var indexByID: [String: Int] = [:]
        for device in snapshots.joined() {
            guard let index = indexByID[device.id] else {
                indexByID[device.id] = result.count
                result.append(device)
                continue
            }
            if rank(device) < rank(result[index]) { result[index] = device }
        }
        return result.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    private static func rank(_ device: DeviceInfo) -> Int {
        (device.state == .connected ? 0 : 2) + (device.connection == .usb ? 0 : 1)
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
        // 先把当前首选传输推给会话，订阅者据此决定重连 / 切换时会话已经用上新的 serial。
        for device in list { sessions[device.id]?.updateDevice(device) }
        for continuation in subscribers.values { continuation.yield(list) }
    }

    private func removeSubscriber(_ id: Int) {
        subscribers[id] = nil
    }
}
