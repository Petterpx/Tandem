import DeviceCore
import Foundation
import Observation

/// 自定义 shell 命令；`{package}` 为目标 App 占位符。
struct CustomCommand: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var command: String

    static let placeholder = "{package}"

    var needsPackage: Bool { command.contains(Self.placeholder) }

    /// 把占位符替换为校验并转义后的包名；无占位符的命令原样返回。
    func render(package: String?) throws -> String {
        guard needsPackage else { return command }
        guard let package else {
            throw DeviceError(code: .INVALID_ARGUMENT, message: "该命令需要目标 App")
        }
        let quoted = ShellQuote.quote(try PackageName.validate(package))
        return command.replacingOccurrences(of: Self.placeholder, with: quoted)
    }
}

/// 快捷操作的持久化状态：置顶 App、链接历史、自定义命令、折叠分组、AI shell 开关。
@MainActor @Observable
final class QuickActionsStore {
    static let maxURLHistory = 20

    private enum Key {
        static let pinned = "quickActions.pinned"
        static let urlHistory = "quickActions.urlHistory"
        static let commands = "quickActions.commands"
        static let collapsed = "quickActions.collapsed"
        static let allowAIShell = "quickActions.allowAIShell"
    }

    private(set) var pinnedPackages: [String]
    private(set) var urlHistory: [String]
    private(set) var commands: [CustomCommand]
    private(set) var collapsedSections: Set<String>
    var allowAIShell: Bool {
        didSet { defaults.set(allowAIShell, forKey: Key.allowAIShell) }
    }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        pinnedPackages = defaults.stringArray(forKey: Key.pinned) ?? []
        urlHistory = defaults.stringArray(forKey: Key.urlHistory) ?? []
        commands = defaults.data(forKey: Key.commands)
            .flatMap { try? JSONDecoder().decode([CustomCommand].self, from: $0) } ?? []
        collapsedSections = Set(defaults.stringArray(forKey: Key.collapsed) ?? [])
        allowAIShell = defaults.object(forKey: Key.allowAIShell) as? Bool ?? true
    }

    // MARK: 置顶 App

    func pin(_ package: String) {
        guard !pinnedPackages.contains(package) else { return }
        pinnedPackages.append(package)
        defaults.set(pinnedPackages, forKey: Key.pinned)
    }

    func unpin(_ package: String) {
        pinnedPackages.removeAll { $0 == package }
        defaults.set(pinnedPackages, forKey: Key.pinned)
    }

    // MARK: 链接历史

    func recordURL(_ url: String) {
        urlHistory.removeAll { $0 == url }
        urlHistory.insert(url, at: 0)
        if urlHistory.count > Self.maxURLHistory {
            urlHistory.removeLast(urlHistory.count - Self.maxURLHistory)
        }
        defaults.set(urlHistory, forKey: Key.urlHistory)
    }

    func removeURL(_ url: String) {
        urlHistory.removeAll { $0 == url }
        defaults.set(urlHistory, forKey: Key.urlHistory)
    }

    // MARK: 自定义命令

    func addCommand(name: String, command: String) {
        commands.append(CustomCommand(id: UUID(), name: name, command: command))
        saveCommands()
    }

    func updateCommand(_ updated: CustomCommand) {
        guard let i = commands.firstIndex(where: { $0.id == updated.id }) else { return }
        commands[i] = updated
        saveCommands()
    }

    func removeCommand(id: UUID) {
        commands.removeAll { $0.id == id }
        saveCommands()
    }

    func moveCommands(from source: IndexSet, to destination: Int) {
        let moving = source.sorted().map { commands[$0] }
        let before = source.filter { $0 < destination }.count
        for i in source.sorted().reversed() { commands.remove(at: i) }
        commands.insert(contentsOf: moving, at: destination - before)
        saveCommands()
    }

    private func saveCommands() {
        defaults.set(try? JSONEncoder().encode(commands), forKey: Key.commands)
    }

    // MARK: 折叠分组

    func toggleSection(_ id: String) {
        if collapsedSections.contains(id) { collapsedSections.remove(id) } else { collapsedSections.insert(id) }
        defaults.set(collapsedSections.sorted(), forKey: Key.collapsed)
    }

    // MARK: 输出截断

    /// 超过 `maxLines` 行时保留前 `maxLines` 行并追加省略说明；末尾换行不算一行。
    /// 结果仍超过 `maxBytes`（UTF-8，如单行极长）时再在字符边界截断，说明里的字节数按原输出计。
    nonisolated static func cappedOutput(_ s: String, maxLines: Int = 200, maxBytes: Int = 256 * 1024) -> String {
        var lines = s.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var kept = s
        var text = s
        if lines.count > maxLines {
            kept = lines.prefix(maxLines).joined(separator: "\n")
            text = kept + "\n…（共 \(lines.count) 行，已省略 \(lines.count - maxLines) 行）"
        }
        guard text.utf8.count > maxBytes else { return text }
        // 说明最长约 60 字节，预留 128 字节
        kept = prefix(kept, bytes: max(0, maxBytes - 128))
        let total = s.utf8.count
        return kept + "\n…（共 \(total) 字节，已省略 \(total - kept.utf8.count) 字节）"
    }

    /// stdout 与 stderr 合在一起显示：stdout 非空且没有结尾换行时补一个，避免 stderr 首行并入 stdout 末行。
    nonisolated static func joinedOutput(stdout: String, stderr: String) -> String {
        stdout.isEmpty || stderr.isEmpty || stdout.hasSuffix("\n") ? stdout + stderr : stdout + "\n" + stderr
    }

    /// 不超过 bytes 个 UTF-8 字节的最长前缀，在字符边界处截断。
    private nonisolated static func prefix(_ s: String, bytes: Int) -> String {
        var used = 0
        var end = s.startIndex
        for i in s.indices {
            used += s[i].utf8.count
            if used > bytes { break }
            end = s.index(after: i)
        }
        return String(s[..<end])
    }
}
