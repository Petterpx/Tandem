import DeviceCore
import Foundation

/// 文件传输的面板入口：推送、安装、拉取都提交到 TransferQueue（由它写记录）；列目录只读不记录。
extension DeviceCommands {
    /// 推送一批本地文件：普通文件与文件夹合为一项推送，每个 APK 各自一项安装。返回入队的项。
    @discardableResult
    func pushFiles(
        _ id: String, _ urls: [URL], dest: String = "/sdcard/Download/", conflict: ConflictPolicy = .rename,
        mediaScan: Bool = false, installAPKs: Bool = true, cleanup: Set<URL> = [], origin: ToastOrigin
    ) -> [UUID] {
        let apks = installAPKs ? urls.filter(Self.isAPK) : []
        let others = urls.filter { !apks.contains($0) }
        var ids: [UUID] = []
        if !others.isEmpty {
            ids.append(transfers.enqueue(
                id, .push(locals: others, dest: dest, conflict: conflict, mediaScan: mediaScan), origin: origin,
                cleanup: others.filter(cleanup.contains)))
        }
        ids += apks.map { installAPK(id, $0, cleanup: cleanup.contains($0), origin: origin) }
        return ids
    }

    /// `cleanup` 为 true 时，安装结束后删除该（临时）文件。
    @discardableResult
    func installAPK(_ id: String, _ url: URL, cleanup: Bool = false, origin: ToastOrigin) -> UUID {
        transfers.enqueue(id, .install(apk: url), origin: origin, cleanup: cleanup ? [url] : [])
    }

    @discardableResult
    func pull(_ id: String, _ remote: String, origin: ToastOrigin) -> UUID {
        transfers.enqueue(id, .pull(remote: remote, to: pullDirectory()), origin: origin)
    }

    /// 拖到 Finder 时的懒拉取：直接拉到新的临时目录（不进队列，避免与 Finder 的回调互相等待），文件名保持远端名。
    /// 经 runner 写一条「拉取 <名>」记录；失败时抛出原因。
    func pullToTemporary(_ id: String, _ remote: String) async throws -> URL {
        let name = (remote as NSString).lastPathComponent
        guard let dev = device(id) else { throw DeviceError(code: .DEVICE_NOT_FOUND, message: "设备不可用") }
        var failure: (any Error)?
        let url = await runner.perform("拉取 \(name)", device: dev) {
            do {
                guard let actions = await actions(id) else {
                    throw DeviceError(code: .DEVICE_NOT_FOUND, message: "设备不可用")
                }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-drag-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = dir.appendingPathComponent(name)
                try await actions.pull(remote, to: url, progress: { _ in })
                return url
            } catch {
                failure = error
                throw error
            }
        }
        guard let url else { throw failure ?? DeviceError(code: .CONNECTION_FAILED, message: "拉取失败") }
        return url
    }

    func listDirectory(_ id: String, _ path: String) async -> Result<[RemoteFile], DeviceError> {
        await read(id) { try await $0.listDirectory(path) }
    }

    /// `.apk` 文件（不含名为 *.apk 的文件夹）。
    private static func isAPK(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "apk" && (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory != true
    }
}
