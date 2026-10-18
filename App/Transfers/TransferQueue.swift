import DeviceCore
import Foundation
import Observation
import os
import UniformTypeIdentifiers

/// 推送时设备上已有同名文件的处理方式。
enum ConflictPolicy: String, Codable { case overwrite, rename }

/// 一项传输。
enum TransferKind: Equatable {
    /// `dest` 以 `/` 结尾视为目录（多个文件时总是视为目录）；文件夹递归推送。
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
    func result(_ jobID: UUID) async -> Result<TransferResult, DeviceError> {
        guard locate(jobID) != nil else {
            return .failure(DeviceError(code: .INVALID_ARGUMENT, message: "没有这项传输"))
        }
        return await withCheckedContinuation { waiters[jobID, default: []].append($0) }
    }

    // MARK: 提交与取消

    @discardableResult
    func enqueue(_ deviceID: String, _ kind: TransferKind, origin: ToastOrigin, source: ActivitySource = .user) -> UUID {
        let job = TransferJob(id: UUID(), deviceID: deviceID, kind: kind, origin: origin, source: source)
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
            // 用户取消不写记录
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

    private func execute(_ job: TransferJob, _ box: ProgressBox) async throws -> (TransferResult, String?) {
        guard let actions = await actions(job.deviceID) else {
            throw DeviceError(code: .DEVICE_NOT_FOUND, message: "设备不可用")
        }
        switch job.kind {
        case .push(let locals, let dest, let conflict, let mediaScan):
            let sizes = await Self.localSizes(locals)
            let total = sizes.reduce(0, +)
            setProgress(job, TransferProgress(bytes: 0, total: total))
            let asDirectory = dest.hasSuffix("/") || locals.count > 1
            var pushed: [String] = []
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
            }
            // 只广播图片、视频；失败不影响推送结果
            let media = pushed.filter(Self.isMedia)
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
            let name = (remote as NSString).lastPathComponent
            guard !name.isEmpty, name != "/" else {
                throw DeviceError(code: .INVALID_ARGUMENT, message: "设备路径不合法：\(remote)")
            }
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let target = TransferNaming.uniqueLocal(in: dir, name: name)
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
        onFinished(job)
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

    private static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
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

    private static func isMedia(_ path: String) -> Bool {
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
