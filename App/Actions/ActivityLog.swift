import Foundation
import Observation

enum ActivitySource: Equatable { case user, ai }

/// 一条操作记录；failure 非空表示这次操作失败。
struct ActivityEntry: Identifiable, Equatable {
    let id: UUID
    let date: Date
    let source: ActivitySource
    let deviceName: String
    let title: String
    let failure: String?
}

/// 操作记录：只保存在内存，最多 500 条，最新在前，不持久化。
@MainActor @Observable
final class ActivityLog {
    static let limit = 500

    private(set) var entries: [ActivityEntry] = []

    func append(_ e: ActivityEntry) {
        entries.insert(e, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    func clear() { entries.removeAll() }
}
