import DeviceCore
import Foundation
import os

/// adb server features 的缓存，AndroidActions（值类型）持有同一个实例。
final class AdbFeatureCache: Sendable {
    private let lock = OSAllocatedUnfairLock<Set<String>?>(initialState: nil)
    var value: Set<String>? {
        get { lock.withLock { $0 } }
        set { lock.withLock { $0 = newValue } }
    }
}

extension AndroidActions {
    public func listDirectory(_ path: String) async throws -> [RemoteFile] {
        let path = try DevicePath.validate(path)
        return try await withSync { try await $0.list(path) }
    }

    public func stat(_ path: String) async throws -> RemoteFile? {
        let path = try DevicePath.validate(path)
        return try await withSync { try await $0.stat(path) }
    }

    /// 文件：`remote` 即目标完整路径；文件夹：递归推送，`remote` 为目标文件夹。
    public func push(_ local: URL, to remote: String, progress: @escaping ProgressHandler) async throws {
        let remote = try DevicePath.validate(remote)
        let plan = try Self.pushPlan(local: local, remote: remote)
        let total = plan.files.reduce(UInt64(0)) { $0 + $1.size }
        // 空文件夹没有文件可推，用 shell 建出。
        for dir in plan.emptyDirectories {
            _ = try await shellChecked("mkdir -p \(ShellQuote.quote(dir))")
        }
        guard !plan.files.isEmpty else { return }
        let current = OSAllocatedUnfairLock<String?>(initialState: nil)
        do {
            try await withSync { session in
                var done: UInt64 = 0
                for file in plan.files {
                    current.withLock { $0 = file.remote }
                    let handle = try FileHandle(forReadingFrom: file.local)
                    defer { try? handle.close() }
                    let base = done
                    try await session.send(
                        file.remote, mode: file.mode, mtime: file.mtime,
                        read: { count in
                            guard let data = try handle.read(upToCount: count), !data.isEmpty else { return nil }
                            return data
                        },
                        progress: { progress(TransferProgress(bytes: base + $0, total: total)) })
                    done += file.size
                }
            }
        } catch {
            // 清理在非结构化任务里跑，不受当前任务已取消的影响；尽力而为。
            if let partial = current.withLock({ $0 }) {
                let (adb, serial) = (adb, serial)
                await Task { _ = try? await adb.run(["shell", "rm -f \(ShellQuote.quote(partial))"], serial: serial) }.value
            }
            throw error
        }
    }

    /// 先写 `<local>.part`，成功后替换为 `local`（已存在则替换）；失败或取消时删除 `.part`。
    public func pull(_ remote: String, to local: URL, progress: @escaping ProgressHandler) async throws {
        let remote = try DevicePath.validate(remote)
        let part = URL(fileURLWithPath: local.path + ".part")
        let fm = FileManager.default
        try? fm.removeItem(at: part)
        guard fm.createFile(atPath: part.path, contents: nil) else {
            throw DeviceError(code: .CONNECTION_FAILED, message: "拉取失败：无法写入 \(part.path)")
        }
        do {
            let handle = try FileHandle(forWritingTo: part)
            defer { try? handle.close() }
            try await withSync { session in
                guard let info = try await session.stat(remote) else {
                    throw DeviceError(code: .CONNECTION_FAILED, message: "拉取失败：文件不存在")
                }
                try await session.recv(
                    remote, write: { try handle.write(contentsOf: $0) },
                    progress: { progress(TransferProgress(bytes: $0, total: info.size)) })
            }
            try handle.close()
            if fm.fileExists(atPath: local.path) {
                _ = try fm.replaceItemAt(local, withItemAt: part)
            } else {
                try fm.moveItem(at: part, to: local)
            }
        } catch {
            try? fm.removeItem(at: part)
            throw error
        }
    }

    // MARK: 内部

    private struct PushFile {
        var local: URL
        var remote: String
        var size: UInt64
        var mode: UInt32
        var mtime: Date
    }

    private struct PushPlan {
        var files: [PushFile] = []
        var emptyDirectories: [String] = []
    }

    private static func pushPlan(local: URL, remote: String) throws -> PushPlan {
        var plan = PushPlan()
        func entry(_ url: URL, _ remotePath: String) throws -> PushFile {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            let perms = (attrs[.posixPermissions] as? NSNumber)?.uint32Value ?? 0o644
            return PushFile(
                local: url, remote: remotePath,
                size: (attrs[.size] as? NSNumber)?.uint64Value ?? 0,
                mode: 0o100000 | (perms & 0o777),
                mtime: attrs[.modificationDate] as? Date ?? Date())
        }
        func walk(_ dir: URL, _ remoteDir: String) throws {
            let children = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if children.isEmpty { plan.emptyDirectories.append(remoteDir) }
            for child in children {
                let childRemote = remoteDir + (remoteDir.hasSuffix("/") ? "" : "/") + child.lastPathComponent
                if (try child.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
                    try walk(child, childRemote)
                } else {
                    plan.files.append(try entry(child, childRemote))
                }
            }
        }
        if (try local.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true {
            try walk(local, remote)
        } else {
            plan.files.append(try entry(local, remote))
        }
        return plan
    }

    /// 连接 adb server；失败时执行一次 `adb start-server` 后重试，仍失败抛「无法连接 adb 服务」。
    private func connect() async throws -> any ByteStream {
        do {
            return try await syncStream()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            _ = try? await adb.run(["start-server"], timeout: .seconds(15))
            do {
                return try await syncStream()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw DeviceError(code: .CONNECTION_FAILED, message: "无法连接 adb 服务")
            }
        }
    }

    private func features() async throws -> Set<String> {
        if let cached = featureCache.value { return cached }
        let stream = try await connect()
        defer { stream.close() }
        let result = try await AdbHost.features(stream, serial: serial)
        featureCache.value = result
        return result
    }

    /// 开一条 sync 会话执行 `body`；成功后 quit，出错一律丢弃连接（不复用）。
    private func withSync<T>(_ body: (AdbSyncSession) async throws -> T) async throws -> T {
        let features = try await features()
        let stream = try await connect()
        do {
            let session = try await AdbSyncSession.open(stream, serial: serial, features: features)
            let value = try await body(session)
            session.quit()
            return value
        } catch {
            stream.close()
            throw error
        }
    }
}
