import Foundation
import Observation

/// 按设备的"锁定 AI 操作"开关，持久化在 UserDefaults（逻辑设备 id 数组）。
@MainActor @Observable
final class AILocks {
    private static let key = "aiLockedDeviceIDs"

    private(set) var lockedIDs: Set<String>
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        lockedIDs = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func isLocked(_ id: String) -> Bool { lockedIDs.contains(id) }

    func setLocked(_ id: String, _ on: Bool) {
        if on { lockedIDs.insert(id) } else { lockedIDs.remove(id) }
        defaults.set(lockedIDs.sorted(), forKey: Self.key)
    }
}
