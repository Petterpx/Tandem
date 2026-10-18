import DeviceCore
import Foundation
import Observation

/// 右栏「文件」标签的状态（spec §3.5）：每台设备各有当前目录与目录列表，互不影响。
@MainActor @Observable
final class FilesModel {
    static let defaultPath = "/sdcard/Download"
    static let shortcuts = ["/sdcard/Download", "/sdcard/DCIM", "/sdcard/Pictures", "/sdcard/Documents"]

    private let commands: DeviceCommands

    /// 按设备 id 的当前目录；未浏览过的设备用默认目录（见 `currentPath`）。
    private(set) var path: [String: String] = [:]
    /// 按设备 id 的最近一次目录列表（目录在前）。
    private(set) var listing: [String: Result<[RemoteFile], DeviceError>] = [:]
    /// 正在读取目录的设备。
    private(set) var loading: Set<String> = []

    /// 每台设备的读取代数：只有最新一次读取的结果才会写入，慢的旧结果被丢弃。
    @ObservationIgnored private var generation: [String: Int] = [:]

    init(commands: DeviceCommands) {
        self.commands = commands
    }

    func currentPath(_ id: String) -> String { path[id] ?? Self.defaultPath }

    /// 推送目标目录（以 `/` 结尾）。
    func pushDestination(_ id: String) -> String {
        let p = currentPath(id)
        return p == "/" ? "/" : p + "/"
    }

    /// 进入目录。路径须为绝对路径，否则不跳转，把原因显示为读取失败。
    func open(_ id: String, _ requested: String) async {
        let target: String
        do {
            target = try Self.normalize(requested)
        } catch let error as DeviceError {
            generation[id, default: 0] += 1
            loading.remove(id)
            listing[id] = .failure(error)
            return
        } catch { return }
        path[id] = target
        await load(id, target)
    }

    func up(_ id: String) async { await open(id, Self.parent(of: currentPath(id))) }

    func refresh(_ id: String) async { await load(id, currentPath(id)) }

    /// 「在文件中查看」：打开该文件所在目录。
    @discardableResult
    func reveal(deviceID: String, path target: String) -> Task<Void, Never> {
        let dir = Self.parent(of: (try? Self.normalize(target)) ?? target)
        path[deviceID] = dir
        return Task { await open(deviceID, dir) }
    }

    /// 传输结束：推送到当前目录的项完成后自动刷新该设备的列表。
    func transferFinished(_ job: TransferJob) {
        guard case .push = job.kind, case .done(.pushed(let paths)) = job.state, let current = path[job.deviceID]
        else { return }
        if paths.contains(where: { Self.parent(of: $0) == current }) {
            Task { await refresh(job.deviceID) }
        }
    }

    private func load(_ id: String, _ target: String) async {
        let gen = generation[id, default: 0] + 1
        generation[id] = gen
        loading.insert(id)
        let result = await commands.listDirectory(id, target)
        guard generation[id] == gen else { return }
        loading.remove(id)
        listing[id] = result.map(Self.sorted)
    }

    // MARK: 路径

    /// 规范化为绝对路径：去掉多余的 `/`，解析 `.` 与 `..`。不是绝对路径或含非法字符时抛 INVALID_ARGUMENT。
    static func normalize(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        _ = try DevicePath.validate(trimmed)
        var parts: [Substring] = []
        for part in trimmed.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// 上级目录；根目录的上级仍是根目录。
    static func parent(of path: String) -> String {
        guard let normalized = try? normalize(path) else { return "/" }
        let parent = (normalized as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    /// 目录在前，其余按名称（本地化自然排序）。
    private static func sorted(_ files: [RemoteFile]) -> [RemoteFile] {
        files.sorted {
            let d0 = $0.kind == .directory, d1 = $1.kind == .directory
            if d0 != d1 { return d0 }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}
