import AppKit
import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct TransferQueueTests {
    private let dev = DeviceInfo(
        serial: "s1", platform: .android, name: "Pixel", state: .connected, connection: .usb,
        hardwareSerial: "HW1", capabilities: [])

    @MainActor private final class Finished { var jobs: [TransferJob] = [] }

    /// 收集结束的项，并可挂起等到结束的项达到指定数量（不轮询）。
    @MainActor private final class FinishWaiter {
        private(set) var jobs: [TransferJob] = []
        private var waiter: (count: Int, continuation: CheckedContinuation<Void, Never>)?

        func add(_ job: TransferJob) {
            jobs.append(job)
            if let w = waiter, jobs.count >= w.count {
                waiter = nil
                w.continuation.resume()
            }
        }

        func wait(for count: Int) async {
            guard jobs.count < count else { return }
            await withCheckedContinuation { waiter = (count, $0) }
        }
    }

    private struct Env {
        let queue: TransferQueue
        let runner: ActionRunner
        let log: ActivityLog
        let actions: RecordingActions
        let finished: Finished
        /// 本地临时目录：放待推送的文件，也作拉取目录。
        let dir: URL
    }

    private func make(actions: RecordingActions = RecordingActions(), interval: Duration = .milliseconds(10)) -> Env {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = ActivityLog()
        let runner = ActionRunner(log: log)
        let finished = Finished()
        let device = dev
        let queue = TransferQueue(
            runner: runner, device: { $0 == device.id ? device : nil },
            actions: { $0 == device.id ? actions : nil },
            onFinished: { finished.jobs.append($0) }, progressInterval: interval)
        return Env(queue: queue, runner: runner, log: log, actions: actions, finished: finished, dir: dir)
    }

    /// 在临时目录里建一个指定字节数的文件。
    private func file(_ name: String, _ e: Env, bytes: Int = 4) -> URL {
        let url = e.dir.appendingPathComponent(name)
        try? Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func push(_ urls: [URL], dest: String = "/sdcard/Download/", conflict: ConflictPolicy = .rename,
                      mediaScan: Bool = false) -> TransferKind {
        .push(locals: urls, dest: dest, conflict: conflict, mediaScan: mediaScan)
    }

    /// 轮询等待条件成立（最多约 2 秒）。
    private func until(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private func isRunning(_ job: TransferJob?) -> Bool {
        if case .running = job?.state { return true }
        return false
    }

    @Test func runsOneAtATimeFIFO() async {
        let actions = RecordingActions()
        let gate = TransferGate()
        actions.transferGate = gate
        let e = make(actions: actions)
        let a = e.queue.enqueue(dev.id, push([file("a.txt", e)]), origin: .workspace)
        let b = e.queue.enqueue(dev.id, push([file("b.txt", e)]), origin: .workspace)
        // 状态先变为进行中，随后才调用 push：等到 push 已调用
        await until { e.actions.calls.contains { $0.hasPrefix("push") } }
        #expect(isRunning(e.queue.jobs(dev.id).first))
        #expect(e.queue.jobs(dev.id).map(\.id) == [a, b])
        #expect(e.queue.jobs(dev.id)[1].state == .waiting)
        #expect(e.actions.calls.filter { $0.hasPrefix("push") } == ["push a.txt /sdcard/Download/a.txt"])

        gate.release()
        await until { e.queue.jobs(dev.id).map(\.id) == [b] && isRunning(e.queue.jobs(dev.id).first) }
        #expect(e.finished.jobs.map(\.id) == [a])
        #expect(e.finished.jobs.first?.state == .done(.pushed(["/sdcard/Download/a.txt"])))

        gate.release()
        await until { e.queue.jobs(dev.id).isEmpty }
        #expect(e.finished.jobs.map(\.id) == [a, b])
        #expect(e.actions.calls.filter { $0.hasPrefix("push") } == [
            "push a.txt /sdcard/Download/a.txt", "push b.txt /sdcard/Download/b.txt",
        ])
    }

    @Test func renameUsesStat() async {
        let e = make()
        e.actions.existingPaths = ["/sdcard/Download/a.jpg"]
        let id = e.queue.enqueue(dev.id, push([file("a.jpg", e)]), origin: .workspace)
        #expect(await e.queue.result(id) == .success(.pushed(["/sdcard/Download/a (1).jpg"])))
        #expect(e.actions.calls == [
            "stat /sdcard/Download/a.jpg", "stat /sdcard/Download/a (1).jpg", "push a.jpg /sdcard/Download/a (1).jpg",
        ])
    }

    /// dest 不以 `/` 结尾且设备上不是目录：作为目标路径；覆盖时不为改名再 stat。
    @Test func overwriteDestWithoutSlashIsTargetPath() async {
        let e = make()
        e.actions.existingPaths = ["/sdcard/x.bin"]
        let id = e.queue.enqueue(dev.id, push([file("a.jpg", e)], dest: "/sdcard/x.bin", conflict: .overwrite),
                                 origin: .workspace)
        #expect(await e.queue.result(id) == .success(.pushed(["/sdcard/x.bin"])))
        #expect(e.actions.calls == ["stat /sdcard/x.bin", "push a.jpg /sdcard/x.bin"])
    }

    /// dest 不以 `/` 结尾但设备上已是目录：推到其中（追加文件名），再按同名规则改名。
    @Test func destWithoutSlashExistingDirectoryAppendsName() async {
        let e = make()
        e.actions.existingDirectories = ["/sdcard/Pictures"]
        e.actions.existingPaths = ["/sdcard/Pictures/a.jpg"]
        let id = e.queue.enqueue(dev.id, push([file("a.jpg", e)], dest: "/sdcard/Pictures"), origin: .workspace)
        #expect(await e.queue.result(id) == .success(.pushed(["/sdcard/Pictures/a (1).jpg"])))
        #expect(e.actions.calls == [
            "stat /sdcard/Pictures", "stat /sdcard/Pictures/a.jpg", "stat /sdcard/Pictures/a (1).jpg",
            "push a.jpg /sdcard/Pictures/a (1).jpg",
        ])
    }

    @Test func apkGoesToInstall() async {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let mac = MacPasteboard(NSPasteboard(name: .init(UUID().uuidString)))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = CaptureStore(pasteboard: mac, defaults: defaults, home: home)
        let e = make()
        let device = dev
        let actions = e.actions
        let commands = DeviceCommands(
            runner: e.runner, store: store, recording: RecordingService(store: store),
            clipboard: ClipboardService(pasteboard: mac, defaults: defaults), toasts: ToastCenter(),
            transfers: e.queue, device: { $0 == device.id ? device : nil }, session: { _ in nil }, sessionState: { _ in nil },
            actions: { $0 == device.id ? actions : nil }, isPopupOpen: { _ in false })
        let gate = TransferGate()
        e.actions.transferGate = gate
        let apk = file("x.apk", e)
        let txt = file("y.txt", e)
        commands.pushFiles(dev.id, [apk, txt], origin: .popup("HW1"))
        let kinds = e.queue.jobs(dev.id).map(\.kind)
        #expect(kinds.count == 2)
        #expect(kinds.contains(.install(apk: apk)))
        #expect(kinds.contains(push([txt])))
        #expect(e.queue.jobs(dev.id).allSatisfy { $0.origin == .popup("HW1") && $0.source == .user })
        gate.release()
        gate.release()
        await until { e.queue.jobs(dev.id).isEmpty }
    }

    @Test func cancelCurrentOnlyCancelsRunning() async {
        let actions = RecordingActions()
        let gate = TransferGate()
        actions.transferGate = gate
        let e = make(actions: actions)
        let a = e.queue.enqueue(dev.id, push([file("a.txt", e)]), origin: .workspace)
        let b = e.queue.enqueue(dev.id, push([file("b.txt", e)]), origin: .workspace)
        await until { isRunning(e.queue.jobs(dev.id).first) }

        e.queue.cancelCurrent(dev.id)
        await until { e.finished.jobs.count == 1 }
        #expect(e.finished.jobs.first?.id == a)
        #expect(e.finished.jobs.first?.state == .cancelled)
        // 下一项接着执行
        await until { isRunning(e.queue.jobs(dev.id).first) }
        #expect(e.queue.jobs(dev.id).map(\.id) == [b])
        // 用户取消记一条失败「已取消」，不弹面板错误
        #expect(e.log.entries.map(\.title) == ["推送 a.txt"])
        #expect(e.log.entries.first?.failure == "已取消")
        #expect(e.runner.lastError == nil)

        gate.release()
        if case .failure(let error) = await e.queue.result(b) { Issue.record("b 应成功：\(error)") }
        #expect(e.log.entries.map(\.title) == ["推送 b.txt", "推送 a.txt"])
        #expect(e.log.entries.first?.failure == nil)
    }

    @Test func disconnectCancelsRest() async {
        let actions = RecordingActions()
        actions.transferGate = TransferGate()
        let e = make(actions: actions)
        let a = e.queue.enqueue(dev.id, push([file("a.txt", e)]), origin: .workspace)
        let b = e.queue.enqueue(dev.id, .install(apk: file("app.apk", e)), origin: .workspace)
        let c = e.queue.enqueue(dev.id, .pull(remote: "/sdcard/x.log", to: e.dir), origin: .workspace, source: .ai)
        await until { isRunning(e.queue.jobs(dev.id).first) }
        let waitA = Task { await e.queue.result(a) }

        e.queue.deviceDisconnected(dev.id)
        await until { e.queue.jobs(dev.id).isEmpty && e.finished.jobs.count == 3 }
        let states = Dictionary(uniqueKeysWithValues: e.finished.jobs.map { ($0.id, $0.state) })
        #expect(states[a] == .failed(DeviceError(code: .DEVICE_NOT_FOUND, message: "设备已断开")))
        #expect(states[b] == .cancelled)
        #expect(states[c] == .cancelled)
        if case .failure(let error) = await waitA.value { #expect(error.message == "设备已断开") } else { Issue.record("应失败") }
        // 当前项与被取消的等待项各写一条失败「设备已断开」；AI 提交的项不由队列记录
        #expect(Set(e.log.entries.map(\.title)) == ["推送 a.txt", "安装 app.apk"])
        #expect(e.log.entries.count == 2)
        #expect(e.log.entries.allSatisfy { $0.failure == "设备已断开" && $0.source == .user })
        #expect(e.actions.calls.filter { $0.hasPrefix("install") || $0.hasPrefix("pull") }.isEmpty)
    }

    @Test func recordTitles() async {
        let e = make()
        let one = e.queue.enqueue(dev.id, push([file("a.jpg", e)]), origin: .workspace)
        let three = e.queue.enqueue(
            dev.id, push([file("1.txt", e), file("2.txt", e), file("3.txt", e)]), origin: .workspace)
        let apk = e.queue.enqueue(dev.id, .install(apk: file("app.apk", e)), origin: .workspace)
        let pull = e.queue.enqueue(dev.id, .pull(remote: "/sdcard/x.log", to: e.dir), origin: .workspace)
        let ai = e.queue.enqueue(dev.id, push([file("b.jpg", e)]), origin: .workspace, source: .ai)
        for id in [one, three, apk, pull, ai] { _ = await e.queue.result(id) }
        // 记录最新在前；AI 提交的项不由队列写记录
        #expect(e.log.entries.map(\.title).reversed() == ["推送 a.jpg", "推送 3 个文件", "安装 app.apk", "拉取 x.log"])
        #expect(e.log.entries.allSatisfy { $0.source == .user && $0.failure == nil })
    }

    @Test func resultAwaitsCompletion() async {
        let actions = RecordingActions()
        let gate = TransferGate()
        actions.transferGate = gate
        actions.installResult = "com.demo"
        let e = make(actions: actions)
        let id = e.queue.enqueue(dev.id, .install(apk: file("app.apk", e)), origin: .workspace, source: .ai)
        let waiter = Task { await e.queue.result(id) }
        await until { isRunning(e.queue.jobs(dev.id).first) }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(e.finished.jobs.isEmpty)
        gate.release()
        #expect(await waiter.value == .success(.installed("com.demo")))
        // 已结束的项不再保留
        if case .success = await e.queue.result(id) { Issue.record("已结束的项不应再有结果") }
    }

    @Test func failureRecordsAndSurfaces() async {
        let e = make()
        e.actions.errors["push"] = DeviceError(code: .CONNECTION_FAILED, message: "推送失败：Permission denied")
        let id = e.queue.enqueue(dev.id, push([file("a.jpg", e)]), origin: .workspace)
        #expect(await e.queue.result(id) == .failure(DeviceError(code: .CONNECTION_FAILED, message: "推送失败：Permission denied")))
        #expect(e.finished.jobs.first?.state == .failed(DeviceError(code: .CONNECTION_FAILED, message: "推送失败：Permission denied")))
        #expect(e.log.entries.first?.failure == "推送失败：Permission denied")
        #expect(e.runner.lastError?.message == "推送失败：Permission denied")
    }

    @Test func mediaScanOnlyForMediaAndFailureIsNote() async {
        let e = make()
        let files = [file("a.jpg", e), file("b.txt", e), file("c.mp4", e)]
        let id = e.queue.enqueue(dev.id, push(files, mediaScan: true), origin: .workspace)
        _ = await e.queue.result(id)
        #expect(e.actions.calls.last == "mediaScan /sdcard/Download/a.jpg,/sdcard/Download/c.mp4")
        #expect(e.finished.jobs.last?.note == nil)

        e.actions.errors["mediaScan"] = DeviceError(code: .CONNECTION_FAILED, message: "广播失败")
        let id2 = e.queue.enqueue(dev.id, push([file("d.png", e)], mediaScan: true), origin: .workspace)
        #expect(await e.queue.result(id2) == .success(.pushed(["/sdcard/Download/d.png"])))
        #expect(e.finished.jobs.last?.note == "未能加入相册")
        #expect(e.log.entries.first?.failure == nil)

        // 没有图片、视频时不广播
        let before = e.actions.calls.count
        let id3 = e.queue.enqueue(dev.id, push([file("e.txt", e)], mediaScan: true), origin: .workspace)
        _ = await e.queue.result(id3)
        #expect(!e.actions.calls[before...].contains { $0.hasPrefix("mediaScan") })
    }

    /// 推送文件夹时，广播其中（递归）的图片、视频，与直接推送的媒体文件一起。
    @Test func mediaScanIncludesMediaInsideFolders() async throws {
        let e = make()
        let folder = e.dir.appendingPathComponent("album")
        try FileManager.default.createDirectory(
            at: folder.appendingPathComponent("sub.jpg"), withIntermediateDirectories: true)  // 名为 .jpg 的目录不算
        try Data([1]).write(to: folder.appendingPathComponent("p.png"))
        try Data([1]).write(to: folder.appendingPathComponent("notes.txt"))
        try Data([1]).write(to: folder.appendingPathComponent("sub.jpg/v.mov"))
        let id = e.queue.enqueue(dev.id, push([file("a.jpg", e), folder], mediaScan: true), origin: .workspace)
        #expect(await e.queue.result(id) == .success(.pushed(["/sdcard/Download/a.jpg", "/sdcard/Download/album"])))
        #expect(e.actions.calls.last
            == "mediaScan /sdcard/Download/a.jpg,/sdcard/Download/album/p.png,/sdcard/Download/album/sub.jpg/v.mov")

        // 失败仍算成功，附注「未能加入相册」
        e.actions.errors["mediaScan"] = DeviceError(code: .CONNECTION_FAILED, message: "广播失败")
        let id2 = e.queue.enqueue(dev.id, push([folder], dest: "/sdcard/Pictures/", conflict: .overwrite, mediaScan: true),
                                  origin: .workspace)
        #expect(await e.queue.result(id2) == .success(.pushed(["/sdcard/Pictures/album"])))
        #expect(e.finished.jobs.last?.note == "未能加入相册")
    }

    @Test func pullUsesUniqueLocalName() async throws {
        let e = make()
        try Data().write(to: e.dir.appendingPathComponent("x.log"))
        let id = e.queue.enqueue(dev.id, .pull(remote: "/sdcard/x.log", to: e.dir), origin: .workspace)
        #expect(await e.queue.result(id) == .success(.pulled(e.dir.appendingPathComponent("x (1).log"))))
        #expect(e.actions.calls == ["pull /sdcard/x.log x (1).log"])
    }

    @Test func pullRejectsDotNames() async {
        let e = make()
        for remote in ["/sdcard/..", "/sdcard/."] {
            let id = e.queue.enqueue(dev.id, .pull(remote: remote, to: e.dir), origin: .workspace)
            #expect(await e.queue.result(id) == .failure(DeviceError(code: .INVALID_ARGUMENT, message: "设备路径不合法：\(remote)")))
        }
        #expect(!e.actions.calls.contains { $0.hasPrefix("pull") })
    }

    /// 两台设备同时把 x.log 拉到同一目录：进行中的拉取占用名字，后者改名，互不覆盖。
    /// 结果经 onFinished 收集：result(_:) 须在该项结束前调用，而放行后两项几乎同时结束。
    @Test(.timeLimit(.minutes(1)))
    func concurrentSameNamePullsGetDistinctTargets() async {
        let actions = RecordingActions()
        let gate = TransferGate()
        actions.transferGate = gate
        let other = DeviceInfo(
            serial: "s2", platform: .android, name: "Other", state: .connected, connection: .usb,
            hardwareSerial: "HW2", capabilities: [])
        let devices = [dev.id: dev, other.id: other]
        let finished = FinishWaiter()
        let queue = TransferQueue(
            runner: ActionRunner(log: ActivityLog()), device: { devices[$0] }, actions: { devices[$0] == nil ? nil : actions },
            onFinished: { finished.add($0) }, progressInterval: .milliseconds(10))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        queue.enqueue(dev.id, .pull(remote: "/sdcard/x.log", to: dir), origin: .workspace)
        queue.enqueue(other.id, .pull(remote: "/sdcard/x.log", to: dir), origin: .workspace)
        // 两项都已开始拉取（都在闸门处挂起），此时目录里还没有任何文件
        await until { actions.calls.filter { $0.hasPrefix("pull") }.count == 2 }
        #expect(Set(actions.calls.filter { $0.hasPrefix("pull") }) == ["pull /sdcard/x.log x.log", "pull /sdcard/x.log x (1).log"])
        gate.release()
        gate.release()
        await finished.wait(for: 2)
        var targets: Set<URL> = []
        for job in finished.jobs { if case .done(.pulled(let url)) = job.state { targets.insert(url) } }
        #expect(targets == [dir.appendingPathComponent("x.log"), dir.appendingPathComponent("x (1).log")])
    }

    /// 占用在拉取结束后释放：之后的拉取按磁盘上实际存在的文件选名。
    @Test func pullReservationReleasedAfterFailure() async {
        let e = make()
        e.actions.errors["pull"] = DeviceError(code: .CONNECTION_FAILED, message: "拉取失败：boom")
        let first = e.queue.enqueue(dev.id, .pull(remote: "/sdcard/x.log", to: e.dir), origin: .workspace)
        _ = await e.queue.result(first)
        e.actions.errors["pull"] = nil
        let second = e.queue.enqueue(dev.id, .pull(remote: "/sdcard/x.log", to: e.dir), origin: .workspace)
        #expect(await e.queue.result(second) == .success(.pulled(e.dir.appendingPathComponent("x.log"))))
    }

    /// 多个文件的进度按本地总大小累计；回调先暂存，按间隔才写入状态。
    @Test func progressIsSummedAndThrottled() async {
        let actions = RecordingActions()
        let gate = TransferGate()
        actions.transferGate = gate
        actions.progressChunks = [TransferProgress(bytes: 2, total: 4), TransferProgress(bytes: 4, total: 4)]
        let e = make(actions: actions)
        let id = e.queue.enqueue(dev.id, push([file("a.txt", e, bytes: 4), file("b.txt", e, bytes: 6)]), origin: .workspace)
        await until { e.queue.jobs(dev.id).first?.state == .running(TransferProgress(bytes: 4, total: 10), phase: "推送") }
        #expect(e.queue.jobs(dev.id).first?.state == .running(TransferProgress(bytes: 4, total: 10), phase: "推送"))
        gate.release()
        await until { e.queue.jobs(dev.id).first?.state == .running(TransferProgress(bytes: 8, total: 10), phase: "推送") }
        #expect(e.queue.jobs(dev.id).first?.state == .running(TransferProgress(bytes: 8, total: 10), phase: "推送"))
        gate.release()
        _ = await e.queue.result(id)

        // 间隔很长时，进度回调不会立刻改动状态（总大小在开始时即写入）
        let slow = RecordingActions()
        slow.transferGate = TransferGate()
        slow.progressChunks = actions.progressChunks
        let s = make(actions: slow, interval: .seconds(3600))
        _ = s.queue.enqueue(dev.id, push([file("a.txt", s, bytes: 4)]), origin: .workspace)
        await until { s.actions.calls.contains { $0.hasPrefix("push") } }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(s.queue.jobs(dev.id).first?.state == .running(TransferProgress(bytes: 0, total: 4), phase: "推送"))
        s.queue.cancelCurrent(dev.id)
        await until { s.queue.jobs(dev.id).isEmpty }
    }

    @Test func installSwitchesPhaseAfterPush() async {
        let actions = RecordingActions()
        let gate = TransferGate()
        actions.transferGate = gate
        actions.progressChunks = [TransferProgress(bytes: 4, total: 4)]
        let e = make(actions: actions)
        let id = e.queue.enqueue(dev.id, .install(apk: file("app.apk", e)), origin: .workspace)
        await until { e.queue.jobs(dev.id).first?.state == .running(TransferProgress(bytes: 4, total: 4), phase: "安装中") }
        #expect(e.queue.jobs(dev.id).first?.state == .running(TransferProgress(bytes: 4, total: 4), phase: "安装中"))
        gate.release()
        _ = await e.queue.result(id)
    }
}
