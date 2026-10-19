import DeviceCore
import Foundation

/// 日志与文件传输的 AI 入口：都不需要投屏会话。get_logs 经 run（成功不写记录，锁定时照常可用），
/// 其余经 act(needsSession: false)（受「禁止 AI 操作」限制），传输进入 TransferQueue 排队并等待结果。
extension AICommands {
    /// 返回给 AI 的日志文本上限（UTF-8 字节，含截断说明）。
    static let logOutputLimit = 64 * 1024
    /// 推送的默认设备目录。
    static let defaultPushDestination = "/sdcard/Download/"

    // MARK: 日志

    /// 首行注明过滤条件与 pid，有附注时第二行为附注，其后每行 `time pid tid L tag: message`。
    func getLogs(_ device: DeviceInfo, app: String?, level: LogLevel, grep: String?, lines: Int) async throws -> String {
        presence.touch(device.id)
        return try await run("get_logs", device) {
            let query = LogQuery(package: app, minLevel: level, grep: grep, lines: lines)
            let snapshot = try await deviceActions(device).logSnapshot(query)
            let pids = snapshot.pids.isEmpty ? "-" : snapshot.pids.map(String.init).joined(separator: ",")
            var text = "# app=\(app ?? "all") level=\(level.rawValue) grep=\(grep ?? "-") pids=\(pids) lines=\(lines)\n"
            if let note = snapshot.note { text += "# \(note)\n" }
            text += LogExport.text(snapshot.entries.enumerated().map { .entry($1, id: $0) })
            return AIText.truncated(text, limit: Self.logOutputLimit)
        }
    }

    // MARK: 文件传输

    /// 推送 Mac 上的文件或文件夹；dest 以 `/` 结尾、或设备上已是目录时视为目录，否则为目标路径。返回设备上的实际路径。
    func pushFile(_ device: DeviceInfo, path: String, dest: String?) async throws -> String {
        let title = "push_file \((path as NSString).lastPathComponent)"
        return try await act(title, device, needsSession: false) {
            let local = try Self.existingLocal(path)
            let remote = try DevicePath.validate(dest ?? Self.defaultPushDestination)
            let result = try await transfer(device, .push(locals: [local], dest: remote, conflict: .rename, mediaScan: false))
            guard case .pushed(let paths) = result, let first = paths.first else {
                throw DeviceError(code: .UNSUPPORTED, message: "推送没有返回设备路径")
            }
            return "已推送到 \(first)"
        }
    }

    /// 拉取设备文件到拉取目录（或其下的相对子目录）。返回 Mac 绝对路径。
    func pullFile(_ device: DeviceInfo, path: String, dest: String?) async throws -> String {
        let title = "pull_file \(path)"
        return try await act(title, device, needsSession: false) {
            let remote = try DevicePath.validate(path)
            let directory = try Self.pullDestination(base: pullDirectory(), relative: dest)
            let result = try await transfer(device, .pull(remote: remote, to: directory))
            guard case .pulled(let url) = result else {
                throw DeviceError(code: .UNSUPPORTED, message: "拉取没有返回本机路径")
            }
            return url.path
        }
    }

    func installApp(_ device: DeviceInfo, path: String) async throws -> String {
        let title = "install_app \((path as NSString).lastPathComponent)"
        return try await act(title, device, needsSession: false) {
            guard path.hasPrefix("/"), path.lowercased().hasSuffix(".apk") else {
                throw DeviceError(code: .INVALID_ARGUMENT, message: "不是 APK 文件：\(path)")
            }
            let apk = try Self.existingLocal(path)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: apk.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                throw DeviceError(code: .INVALID_ARGUMENT, message: "不是 APK 文件：\(path)")
            }
            let result = try await transfer(device, .install(apk: apk))
            guard case .installed(let package) = result else {
                throw DeviceError(code: .UNSUPPORTED, message: "安装没有返回结果")
            }
            return package.map { "安装成功：\($0)" } ?? "安装成功"
        }
    }

    /// 入队后立刻等结果：enqueue 与 result 之间不能有挂起点，否则任务可能已结束。
    private func transfer(_ device: DeviceInfo, _ kind: TransferKind) async throws -> TransferResult {
        let id = transfers.enqueue(device.id, kind, origin: origin(device.id), source: .ai)
        switch await transfers.result(id) {
        case .success(let result): return result
        case .failure(let error): throw error
        }
    }

    private static func existingLocal(_ path: String) throws -> URL {
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path) else {
            throw DeviceError(code: .INVALID_ARGUMENT, message: "本机文件不存在：\(path)")
        }
        return URL(fileURLWithPath: path)
    }

    // MARK: 拉取目录沙箱

    /// relative 为拉取目录下的相对子目录（不存在时创建）。绝对路径、含 `..` 分段，
    /// 或解析符号链接后不在 base 之下，都抛 INVALID_ARGUMENT。
    static func pullDestination(base: URL, relative: String?) throws -> URL {
        guard let relative, !relative.isEmpty else { return base }
        let escape = DeviceError(code: .INVALID_ARGUMENT, message: "目标目录必须在拉取目录之内")
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard !relative.hasPrefix("/"), !parts.contains("..") else { throw escape }
        let target = parts.reduce(base) { $0.appendingPathComponent(String($1)) }
        let root = resolved(base)
        // 创建之前先查：已存在的符号链接在这里就会解析到 base 之外
        guard isInside(resolved(target), root) else { throw escape }
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            // 途中已有同名文件或悬空的符号链接：与越界同样处理；其余原因（如无权限）给出通用错误
            if blockedByNonDirectory(base: base, parts: parts) { throw escape }
            throw DeviceError(code: .CONNECTION_FAILED, message: "无法创建目录：\(target.path)")
        }
        // 创建过程中路径可能被换成符号链接：再查一次
        guard isInside(resolved(target), root) else { throw escape }
        return target
    }

    /// base 之下的各级路径中，是否有已存在却不是目录的项（普通文件，或指向文件、悬空的符号链接）。
    private static func blockedByNonDirectory(base: URL, parts: [Substring]) -> Bool {
        let fm = FileManager.default
        var url = base
        for part in parts {
            url = url.appendingPathComponent(String(part))
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                if !isDirectory.boolValue { return true }
            } else if (try? fm.destinationOfSymbolicLink(atPath: url.path)) != nil {
                return true  // 悬空的符号链接
            } else {
                return false
            }
        }
        return false
    }

    /// 解析符号链接；尚不存在的尾部保持原样，只解析最深的已存在祖先。
    private static func resolved(_ url: URL) -> URL {
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            tail.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        return tail.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }
    }

    /// 按路径分段比较，`/x/Downloads2` 不在 `/x/Downloads` 之内。
    private static func isInside(_ url: URL, _ root: URL) -> Bool {
        url.pathComponents.starts(with: root.pathComponents)
    }
}
