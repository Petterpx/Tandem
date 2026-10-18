import Foundation
import Observation

/// 「粘贴文件时」记住的选择（直接推送时按它执行）。
struct PasteChoice: Codable, Equatable {
    var dest: String
    var installAPK: Bool
    var mediaScan: Bool
    var conflict: ConflictPolicy
    var heicToJPEG: Bool
}

/// 文件传输的持久化状态：拉取目录、记住的粘贴选择、最近使用的设备目录。
@MainActor @Observable
final class FileTransferStore {
    static let maxRecentDirectories = 5

    private enum Key {
        static let pullDirectory = "transfers.pullDirectory"
        static let rememberedPaste = "transfers.rememberedPaste"
        static let recentDirectories = "transfers.recentDirectories"
    }

    /// 拉取保存目录，默认 ~/Downloads。
    var pullDirectory: URL {
        didSet { defaults.set(pullDirectory.path, forKey: Key.pullDirectory) }
    }
    /// nil 表示每次询问。
    var rememberedPaste: PasteChoice? {
        didSet {
            if let choice = rememberedPaste, let data = try? JSONEncoder().encode(choice) {
                defaults.set(data, forKey: Key.rememberedPaste)
            } else {
                defaults.removeObject(forKey: Key.rememberedPaste)
            }
        }
    }
    private(set) var recentDirectories: [String]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults, home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.defaults = defaults
        pullDirectory = defaults.string(forKey: Key.pullDirectory).map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent("Downloads")
        rememberedPaste = defaults.data(forKey: Key.rememberedPaste)
            .flatMap { try? JSONDecoder().decode(PasteChoice.self, from: $0) }
        recentDirectories = defaults.stringArray(forKey: Key.recentDirectories) ?? []
    }

    /// 记录用过的设备目录：去重、移到最前、最多 5 个。
    func recordDirectory(_ path: String) {
        recentDirectories.removeAll { $0 == path }
        recentDirectories.insert(path, at: 0)
        if recentDirectories.count > Self.maxRecentDirectories {
            recentDirectories.removeLast(recentDirectories.count - Self.maxRecentDirectories)
        }
        defaults.set(recentDirectories, forKey: Key.recentDirectories)
    }
}
