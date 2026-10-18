import DeviceCore
import Foundation
import Observation
import os

enum ClipboardDirection: Equatable { case read, write, sync }

struct ClipboardRecord: Identifiable, Equatable {
    let id: UUID
    let direction: ClipboardDirection
    let text: String
    let date: Date
}

/// 写入来源：输入框优先，其次 Mac 剪贴板文本。
enum WriteSource: Equatable {
    case input(String)
    case macClipboard(String)
    case unavailable
}

/// 剪贴板标签的后端：读 / 写 / 历史，以及按设备开关的双向自动同步。
@MainActor @Observable
final class ClipboardService {
    static let historyLimit = 10
    /// 同步轮询间隔（Mac 与设备共用）。
    static let pollInterval: Duration = .milliseconds(500)

    private(set) var history: [String: [ClipboardRecord]] = [:]
    private(set) var preview: [String: String] = [:]
    private(set) var syncEnabledIDs: Set<String> = []

    @ObservationIgnored private let pasteboard: MacPasteboard
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var syncGuard = ClipboardSyncGuard()
    /// 已取得设备轮询基准的设备（首次读取只记录基准）。
    @ObservationIgnored private var baselined: Set<String> = []
    @ObservationIgnored private var lastSeenChange: Int
    @ObservationIgnored private let log = Logger(subsystem: "app.tandem", category: "clipboard")

    init(pasteboard: MacPasteboard, defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.pasteboard = pasteboard
        self.defaults = defaults
        self.now = now
        self.lastSeenChange = pasteboard.changeCount
        // UserDefaults 里所有 clipboardSync.<id> 为真的设备
        let prefix = "clipboardSync."
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            if (value as? Bool) == true { syncEnabledIDs.insert(String(key.dropFirst(prefix.count))) }
        }
    }

    // MARK: 同步开关

    func isSyncEnabled(_ id: String) -> Bool { syncEnabledIDs.contains(id) }

    func setSyncEnabled(_ id: String, _ on: Bool) {
        defaults.set(on, forKey: "clipboardSync.\(id)")
        if on {
            syncEnabledIDs.insert(id)
        } else {
            syncEnabledIDs.remove(id)
            baselined.remove(id)
            syncGuard.reset(id)
        }
    }

    // MARK: 读 / 写

    /// Mac 剪贴板当前的文本（写入来源的备选）。
    var macText: String? { pasteboard.string() }

    /// 把历史文本复制到 Mac 剪贴板；经 MacPasteboard 写入，算自己的改动，不会回推给设备。
    func copyToMac(_ text: String) { pasteboard.writeString(text) }

    static func writeSource(input: String, macText: String?) -> WriteSource {
        if !input.isEmpty { return .input(input) }
        if let macText { return .macClipboard(macText) }
        return .unavailable
    }

    func read(_ id: String, session: any DeviceSession) async throws -> String {
        let text = try await session.getClipboard()
        preview[id] = text
        pasteboard.writeString(text)
        syncGuard.note(id, text)
        record(id, .read, text)
        return text
    }

    func write(_ id: String, text: String, paste: Bool, session: any DeviceSession) async throws {
        try await session.setClipboard(text, paste: paste)
        syncGuard.note(id, text)
        record(id, .write, text)
    }

    // MARK: 自动同步

    /// 设备 → Mac（事件或轮询共用）：同步关闭时忽略。
    func deviceClipboardChanged(_ id: String, text: String) {
        guard isSyncEnabled(id), syncGuard.shouldSendToMac(id, text) else { return }
        pasteboard.writeString(text)
        record(id, .sync, text)
    }

    /// Mac → 设备：Mac 剪贴板出现新的外部文本时，写给每台开启同步的设备（不粘贴）。
    func pollMac(sessions: [String: any DeviceSession]) async {
        let change = pasteboard.changeCount
        guard change != lastSeenChange else { return }
        lastSeenChange = change
        guard !pasteboard.isOwnChange(change), let text = pasteboard.string() else { return }
        for id in syncEnabledIDs.sorted() {
            guard let session = sessions[id], syncGuard.shouldSendToDevice(id, text) else { continue }
            do {
                try await session.setClipboard(text, paste: false)
                // 送达后才记录，失败时设备旧内容不会被当作新变化覆盖 Mac
                syncGuard.note(id, text)
                record(id, .sync, text)
            } catch {
                log.error("clipboard push to \(id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// 设备 → Mac 的轮询：首次成功读取只记基准，之后内容变化才同步；读取失败直接忽略。
    func pollDevices(sessions: [String: any DeviceSession]) async {
        for id in syncEnabledIDs.sorted() {
            guard let session = sessions[id], let text = try? await session.getClipboard() else { continue }
            // 等待期间可能已被关闭同步
            guard isSyncEnabled(id) else { continue }
            if baselined.insert(id).inserted {
                syncGuard.note(id, text)
            } else {
                deviceClipboardChanged(id, text: text)
            }
        }
    }

    /// 同步循环：只要有设备开启同步，每 0.5 秒依次轮询 Mac 与设备，直到任务被取消。
    func runSyncLoop(sessions: @escaping @MainActor () -> [String: any DeviceSession]) async {
        while !Task.isCancelled {
            if !syncEnabledIDs.isEmpty {
                let current = sessions()
                await pollMac(sessions: current)
                await pollDevices(sessions: current)
            } else {
                // 没有设备开启同步时也推进 changeCount，避免之后开启时回传旧内容
                lastSeenChange = pasteboard.changeCount
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }

    private func record(_ id: String, _ direction: ClipboardDirection, _ text: String) {
        var list = history[id] ?? []
        list.insert(ClipboardRecord(id: UUID(), direction: direction, text: text, date: now()), at: 0)
        if list.count > Self.historyLimit { list.removeLast(list.count - Self.historyLimit) }
        history[id] = list
    }
}
