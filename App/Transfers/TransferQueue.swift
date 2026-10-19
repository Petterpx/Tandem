import DeviceCore
import Foundation
import Observation
import os
import UniformTypeIdentifiers

/// 推送时设备上已有同名文件的处理方式。
enum ConflictPolicy: String, Codable { case overwrite, rename }

/// 一项传输。
enum TransferKind: Equatable {
    /// `dest` 以 `/` 结尾或设备上已是目录时视为目录（多个文件时总是视为目录）；文件夹递归推送。
    case push(locals: [URL], dest: String, conflict: ConflictPolicy, mediaScan: Bool)
    case install(apk: URL)
    /// 拉到 Mac 目录 `to`，同名自动改名。
    case pull(remote: String, to: URL)

    /// 记录与进度栏的标题：`推送 a.jpg`、`推送 3 个文件`、`安装 app.apk`、`拉取 x.log`。
    var title: String {
        switch self {
        case .push(let locals, _, _, _):
            locals.count == 1 ? "推送 \(locals[0].lastPathComponent)" : "推送 \(locals.count) 个文件"
        case .install(let apk): "安装 \(apk.lastPathComponent)"
        case .pull(let remote, _): "拉取 \((remote as NSString).lastPathComponent)"
        }
    }
}

enum TransferResult: Equatable {
    /// 设备上的实际路径。
    case pushed([String])
    /// 包名；Mac 上读不到时为 nil。
    case installed(String?)
    /// Mac 上的实际路径。
    case pulled(URL)
}

struct TransferJob: Identifiable, Equatable {
    enum State: Equatable {
        case waiting
        /// phase 为「推送」「安装中」「拉取」。
        case running(TransferProgress, phase: String)
        case done(TransferResult)
        case failed(DeviceError)
        case cancelled
    }

    let id: UUID
    let deviceID: String
    let kind: TransferKind
    let origin: ToastOrigin
    let source: ActivitySource
    var state: State = .waiting
    /// 成功但有附注，如「未能加入相册」。
    var note: String?
    /// 任务结束（成功、失败、取消）后删除的临时文件。
    var cleanup: [URL] = []
}

/// 按设备排队的传输：每台设备一个 FIFO 队列，一次执行一项。
/// 来源为「你」的项经 runner.perform 写一条记录；AI 提交的项由 AICommands 记录，这里只执行。
@MainActor @Observable
final class TransferQueue {
    private let runner: ActionRunner
    private let device: (String) -> DeviceInfo?
    private let actions: (String) async -> (any DeviceActions)?
    private let onFinished: (TransferJob) -> Void
    private let progressInterval: Duration

    /// 按设备的未完成项，顺序即执行顺序；首项可能正在执行。
    private var queues: [String: [TransferJob]] = [:]

    /// 正在执行的项及其取消原因。
    private struct Running {
        enum Reason { case user, disconnected }
        let jobID: UUID
        let task: Task<(TransferResult, String?), any Error>
        var cancelled: Reason?
    }

    @ObservationIgnored private var running: [String: Running] = [:]
    /// 正在依次执行队列的设备。
    @ObservationIgnored private var draining: Set<String> = []
    @ObservationIgnored private var waiters: [UUID: [CheckedContinuation<Result<TransferResult, DeviceError>, Never>]] = [:]
    /// 入队时的设备信息：设备离开列表后仍能写记录。
    @ObservationIgnored private var enqueuedDevices: [UUID: DeviceInfo] = [:]
    /// 进行中的拉取已选定的本机路径（标准化后）：不同设备同时拉取同名文件时各得各的名字，拉取结束即释放。
    @ObservationIgnored private var reservedLocals: Set<String> = []

    private static let disconnectedError = DeviceError(code: .DEVICE_NOT_FOUND, message: "设备已断开")

    init(
        runner: ActionRunner, device: @escaping (String) -> DeviceInfo?,
        actions: @escaping (String) async -> (any DeviceActions)?,
        onFinished: @escaping (TransferJob) -> Void, progressInterval: Duration = .milliseconds(100)
    ) {
        self.runner = runner
        self.device = device
        self.actions = actions
        self.onFinished = onFinished
        self.progressInterval = progressInterval
    }

    // MARK: 查询

    /// 该设备未完成的项，按执行顺序。
    func jobs(_ deviceID: String) -> [TransferJob] { queues[deviceID] ?? [] }

    /// 有未完成项的设备。
    var busyDeviceIDs: Set<String> { Set(queues.keys) }

    /// 等待这一项结束（AI 用）；已取消或失败的项返回失败。已结束并移出队列的项返回 INVALID_ARGUMENT。
    /// 须在该项结束前调用：在 enqueue 之后立即调用，中间不要有挂起点。
    func result(_ jobID: UUID) async -> Result<TransferResult, DeviceError> {
        guard locate(jobID) != nil else {
            return .failure(DeviceError(code: .INVALID_ARGUMENT, message: "没有这项传输"))
        }
        return await withCheckedContinuation { waiters[jobID, default: []].append($0) }
    }

    // MARK: 提交与取消

    @discardableResult
    func enqueue(
        _ deviceID: String, _ kind: TransferKind, origin: ToastOrigin, source: ActivitySource = .user,
        cleanup: [URL] = []
    ) -> UUID {
        let job = TransferJob(
            id: UUID(), deviceID: deviceID, kind: kind, origin: origin, source: source, cleanup: cleanup)
        queues[deviceID, default: []].append(job)
        enqueuedDevices[job.id] = device(deviceID)
        if draining.insert(deviceID).inserted {
            Task { await drain(deviceID) }
        }
        return job.id
    }

    /// 只取消正在执行的项；它以「已取消」结束，队列继续下一项。
    func cancelCurrent(_ deviceID: String) {
        guard running[deviceID] != nil else { return }
        if running[deviceID]?.cancelled == nil { running[deviceID]?.cancelled = .user }
        running[deviceID]?.task.cancel()
    }

    /// 设备断开：当前项以「设备已断开」失败（底层传输随任务取消而停止），其余项取消。
    func deviceDisconnected(_ deviceID: String) {
        let current = running[deviceID]?.jobID
        if current != nil {
            running[deviceID]?.cancelled = .disconnected
            running[deviceID]?.task.cancel()
        }
        for job in jobs(deviceID) where job.id != current {
            note(job, failure: "设备已断开")
            finish(job.id, .cancelled, DeviceError(code: .DEVICE_NOT_FOUND, message: "设备已断开，传输已取消"))
        }
    }

    // MARK: 执行

    private func drain(_ deviceID: String) async {
        while let job = queues[deviceID]?.first {
            await run(job)
        }
        draining.remove(deviceID)
    }

    private func run(_ job: TransferJob) async {
        let box = ProgressBox()
        update(job.id) { $0.state = .running(TransferProgress(bytes: 0, total: nil), phase: Self.phase(job.kind, nil)) }
        let task = Task { try await execute(job, box) }
        running[job.deviceID] = Running(jobID: job.id, task: task)
        // 进度回调在后台写入 box，这里按间隔取出，界面最多每个间隔更新一次
        let interval = progressInterval
        let ticker = Task { [weak self] in
            while true {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, let p = box.take() else { continue }
                self.setProgress(job, p)
            }
        }
        let outcome = await task.result
        ticker.cancel()
        let reason = running[job.deviceID]?.cancelled
        // 写完记录、移出队列后才清掉：这期间的断开不会把本项当成等待项取消
        defer { running[job.deviceID] = nil }

        switch (outcome, reason) {
        case (.success(let (result, note)), _):
            update(job.id) { $0.note = note }
            await record(job) { result }
            finish(job.id, .done(result), nil)
        case (.failure, .disconnected):
            await record(job) { throw Self.disconnectedError }
            finish(job.id, .failed(Self.disconnectedError), Self.disconnectedError)
        case (.failure, .user), (.failure(is CancellationError), nil):
            // 用户取消记为失败「已取消」，不弹面板错误
            note(job, failure: "已取消")
            finish(job.id, .cancelled, DeviceError(code: .CONNECTION_FAILED, message: "传输已取消"))
        case (.failure(let error), nil):
            let e = Self.deviceError(error)
            await record(job) { throw e }
            finish(job.id, .failed(e), e)
        }
    }

    /// 来源为「你」的项经 runner.perform 写记录（失败同时成为面板错误）。
    private func record(_ job: TransferJob, _ outcome: () throws -> TransferResult) async {
        guard job.source == .user, let dev = device(job.deviceID) ?? enqueuedDevices[job.id] else { return }
        await runner.perform(job.kind.title, device: dev, source: .user) { try outcome() }
    }

    /// 来源为「你」的项只写一条失败记录，不设面板错误（取消）。
    private func note(_ job: TransferJob, failure: String) {
        guard job.source == .user, let dev = device(job.deviceID) ?? enqueuedDevices[job.id] else { return }
        runner.note(job.kind.title, device: dev, source: .user, failure: failure)
    }

    private func execute(_ job: TransferJob, _ box: ProgressBox) async throws -> (TransferResult, String?) {
        guard let actions = await actions(job.deviceID) else {
            throw DeviceError(code: .DEVICE_NOT_FOUND, message: "设备不可用")
        }
        switch job.kind {
        case .push(let locals, let dest, let conflict, let mediaScan):
            let sizes = await Self.localSizes(locals)
            let total = sizes.reduce(0, +)
            setProgress(job, TransferProgress(bytes: 0, total: total))
            // dest 不以 `/` 结尾但设备上已是目录时，同样视为目录（推到其中）
            let asDirectory = try await Self.isDirectoryDestination(dest, count: locals.count, actions)
            var pushed: [String] = []
            var media: [String] = []
            var done: UInt64 = 0
            for (local, size) in zip(locals, sizes) {
                try Task.checkCancellation()
                var target = try DevicePath.validate(asDirectory ? Self.join(dest, local.lastPathComponent) : dest)
                if conflict == .rename { target = try await Self.freeName(target, actions) }
                let base = done
                try await actions.push(local, to: target) {
                    box.put(TransferProgress(bytes: base + $0.bytes, total: total))
                }
                done += size
                pushed.append(target)
                if mediaScan { media += await Self.mediaPaths(local: local, remote: target) }
            }
            // 只广播图片、视频（含文件夹里的）；失败不影响推送结果
            var note: String?
            if mediaScan, !media.isEmpty {
                do { try await actions.mediaScan(media) } catch { note = "未能加入相册" }
            }
            return (.pushed(pushed), note)
        case .install(let apk):
            setProgress(job, TransferProgress(bytes: 0, total: await Self.localSizes([apk]).first))
            let package = try await actions.install(apk: apk) { box.put($0) }
            return (.installed(package), nil)
        case .pull(let remote, let dir):
            let remote = try DevicePath.validate(remote)
            let name = try TransferNaming.localName(forRemote: remote)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // 选名与占用之间没有挂起点：同一时刻只有一项能选中某个名字
            let target = TransferNaming.uniqueLocal(in: dir, name: name, reserved: reservedLocals)
            let key = target.standardizedFileURL.path
            reservedLocals.insert(key)
            defer { reservedLocals.remove(key) }
            try await actions.pull(remote, to: target) { box.put($0) }
            return (.pulled(target), nil)
        }
    }

    // MARK: 状态

    private func locate(_ jobID: UUID) -> (deviceID: String, index: Int)? {
        for (deviceID, list) in queues {
            if let i = list.firstIndex(where: { $0.id == jobID }) { return (deviceID, i) }
        }
        return nil
    }

    private func update(_ jobID: UUID, _ change: (inout TransferJob) -> Void) {
        guard let (deviceID, i) = locate(jobID) else { return }
        change(&queues[deviceID]![i])
    }

    private func setProgress(_ job: TransferJob, _ p: TransferProgress) {
        update(job.id) { $0.state = .running(p, phase: Self.phase(job.kind, p)) }
    }

    /// 移出队列，通知等待者与 onFinished；已结束的项不再保留。
    private func finish(_ jobID: UUID, _ state: TransferJob.State, _ error: DeviceError?) {
        guard let (deviceID, i) = locate(jobID) else { return }
        var job = queues[deviceID]!.remove(at: i)
        if queues[deviceID]!.isEmpty { queues[deviceID] = nil }
        job.state = state
        enqueuedDevices[jobID] = nil
        let result: Result<TransferResult, DeviceError> = if case .done(let r) = state { .success(r) } else {
            .failure(error ?? DeviceError(code: .CONNECTION_FAILED, message: "传输已取消"))
        }
        waiters.removeValue(forKey: jobID)?.forEach { $0.resume(returning: result) }
        Self.removeTemporaries(job.cleanup)
        onFinished(job)
    }

    /// 删除临时文件；所在目录空了（粘贴时每次一个独立子目录）一并删除。
    static func removeTemporaries(_ urls: [URL]) {
        let fm = FileManager.default
        for url in urls {
            try? fm.removeItem(at: url)
            let dir = url.deletingLastPathComponent()
            if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true { try? fm.removeItem(at: dir) }
        }
    }

    // MARK: 辅助

    private static func phase(_ kind: TransferKind, _ p: TransferProgress?) -> String {
        switch kind {
        case .push: "推送"
        case .pull: "拉取"
        case .install:
            // 临时文件推完即进入 pm install
            if let p, let total = p.total, p.bytes >= total, total > 0 { "安装中" } else { "推送" }
        }
    }

    private static func deviceError(_ error: any Error) -> DeviceError {
        if let e = error as? DeviceError { return e }
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return DeviceError(code: .CONNECTION_FAILED, message: message)
    }

    nonisolated private static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    /// 推送目标是否按目录处理：以 `/` 结尾、推送多项，或设备上已存在同名目录（stat 读不到时按目标路径处理）。
    private static func isDirectoryDestination(_ dest: String, count: Int, _ actions: any DeviceActions) async throws -> Bool {
        if dest.hasSuffix("/") || count > 1 { return true }
        let path = try DevicePath.validate(dest)
        return (try? await actions.stat(path))?.kind == .directory
    }

    /// 用 stat 找第一个不存在的名字：`a.jpg`、`a (1).jpg`、`a (2).jpg`…
    private static func freeName(_ target: String, _ actions: any DeviceActions) async throws -> String {
        let dir = (target as NSString).deletingLastPathComponent
        let name = (target as NSString).lastPathComponent
        for n in 0..<1000 {
            let path = n == 0 ? target : join(dir, TransferNaming.candidate(name, n))
            if try await actions.stat(path) == nil { return path }
        }
        throw DeviceError(code: .INVALID_ARGUMENT, message: "目标目录中同名文件过多：\(name)")
    }

    /// 推送后需要广播的设备路径：文件按目标路径判断；文件夹递归找出其中的图片、视频。
    nonisolated private static func mediaPaths(local: URL, remote: String) async -> [String] {
        guard (try? local.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
            return isMedia(remote) ? [remote] : []
        }
        // 按路径枚举直接得到相对路径；目录本身的扩展名不会被当成图片、视频
        var paths: [String] = []
        let files = FileManager.default.enumerator(atPath: local.path)
        while let relative = files?.nextObject() as? String {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: local.appendingPathComponent(relative).path, isDirectory: &isDir)
            guard exists, !isDir.boolValue else { continue }
            let path = join(remote, relative)
            if isMedia(path) { paths.append(path) }
        }
        return paths.sorted()
    }

    nonisolated private static func isMedia(_ path: String) -> Bool {
        guard let type = UTType(filenameExtension: (path as NSString).pathExtension) else { return false }
        return type.conforms(to: .image) || type.conforms(to: .movie)
    }

    /// 各本地项的字节数，文件夹递归求和；在后台执行，不阻塞主线程。
    nonisolated private static func localSizes(_ urls: [URL]) async -> [UInt64] {
        urls.map { url in
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey]
            guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
            guard values.isDirectory == true else { return UInt64(values.fileSize ?? 0) }
            var sum: UInt64 = 0
            let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
            while let child = files?.nextObject() as? URL {
                if let v = try? child.resourceValues(forKeys: keys), v.isDirectory != true {
                    sum += UInt64(v.fileSize ?? 0)
                }
            }
            return sum
        }
    }
}

/// 进度暂存：回调在后台写入最新值，主线程按间隔取出（取出后清空，未变化时不再更新）。
private final class ProgressBox: Sendable {
    private let latest = OSAllocatedUnfairLock<TransferProgress?>(initialState: nil)

    func put(_ p: TransferProgress) { latest.withLock { $0 = p } }

    func take() -> TransferProgress? {
        latest.withLock { p in
            defer { p = nil }
            return p
        }
    }
}
