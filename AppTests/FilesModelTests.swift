import AppKit
import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct FilesModelTests {
    private func device(_ serial: String) -> DeviceInfo {
        DeviceInfo(
            serial: serial, platform: .android, name: serial, state: .connected, connection: .usb,
            hardwareSerial: "HW-\(serial)", capabilities: [.files])
    }

    private struct Env {
        let model: FilesModel
        let commands: DeviceCommands
        let log: ActivityLog
        let a: DeviceInfo
        let b: DeviceInfo
        let actionsA: RecordingActions
        let actionsB: RecordingActions
    }

    private func make() -> Env {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let mac = MacPasteboard(NSPasteboard(name: .init(UUID().uuidString)))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = CaptureStore(pasteboard: mac, defaults: defaults, home: home)
        let log = ActivityLog()
        let runner = ActionRunner(log: log)
        let a = device("A"), b = device("B")
        let actionsA = RecordingActions(), actionsB = RecordingActions()
        let devices = [a.id: a, b.id: b]
        let actions: [String: RecordingActions] = [a.id: actionsA, b.id: actionsB]
        let commands = DeviceCommands(
            runner: runner, store: store, recording: RecordingService(store: store),
            clipboard: ClipboardService(pasteboard: mac, defaults: defaults), toasts: ToastCenter(),
            transfers: TransferQueue(
                runner: runner, device: { devices[$0] }, actions: { actions[$0] }, onFinished: { _ in }),
            device: { devices[$0] }, session: { _ in nil }, actions: { actions[$0] }, isPopupOpen: { _ in false },
            pullDirectory: { home })
        return Env(model: FilesModel(commands: commands), commands: commands, log: log, a: a, b: b,
                   actionsA: actionsA, actionsB: actionsB)
    }

    private func file(_ name: String, in dir: String = "/sdcard/Download") -> RemoteFile {
        RemoteFile(name: name, path: "\(dir)/\(name)", kind: .file, size: 1, modified: Date())
    }

    private func names(_ result: Result<[RemoteFile], DeviceError>?) -> [String]? {
        if case .success(let files)? = result { return files.map(\.name) }
        return nil
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func defaultPathIsDownload() {
        let e = make()
        #expect(e.model.currentPath(e.a.id) == "/sdcard/Download")
        #expect(FilesModel.shortcuts.first == "/sdcard/Download")
    }

    @Test func upStopsAtRoot() async {
        let e = make()
        await e.model.open(e.a.id, "/sdcard/Download")
        await e.model.up(e.a.id)
        #expect(e.model.currentPath(e.a.id) == "/sdcard")
        await e.model.up(e.a.id)
        #expect(e.model.currentPath(e.a.id) == "/")
        await e.model.up(e.a.id)
        #expect(e.model.currentPath(e.a.id) == "/")
    }

    @Test func openNormalizesTrailingSlashes() async {
        let e = make()
        await e.model.open(e.a.id, "/sdcard/DCIM//")
        #expect(e.model.currentPath(e.a.id) == "/sdcard/DCIM")
        #expect(e.actionsA.calls.contains("listDirectory /sdcard/DCIM"))
    }

    @Test func relativePathShowsFailureWithoutNavigating() async {
        let e = make()
        await e.model.open(e.a.id, "sdcard")
        #expect(e.model.currentPath(e.a.id) == "/sdcard/Download")
        if case .failure(let error)? = e.model.listing[e.a.id] { #expect(error.code == .INVALID_ARGUMENT) } else {
            Issue.record("expected failure")
        }
        #expect(e.actionsA.calls.isEmpty)
    }

    @Test func listingSortsDirectoriesFirst() async {
        let e = make()
        e.actionsA.listDirectoryResult = [
            file("b.txt"), RemoteFile(name: "z", path: "/sdcard/Download/z", kind: .directory, size: 0, modified: Date()),
            file("a.txt")]
        await e.model.open(e.a.id, "/sdcard/Download")
        #expect(names(e.model.listing[e.a.id]) == ["z", "a.txt", "b.txt"])
    }

    @Test func staleListingDoesNotOverwriteOtherDevice() async {
        let e = make()
        let gate = TransferGate()
        e.actionsA.listDirectoryResult = [file("a.txt")]
        e.actionsA.listDirectoryHook = { _ in try? await gate.wait() }
        e.actionsB.listDirectoryResult = [file("b.txt")]
        let slow = Task { await e.model.open(e.a.id, "/sdcard/Download") }
        await until { e.actionsA.calls.count == 1 }
        await e.model.open(e.b.id, "/sdcard/Download")
        gate.release()
        await slow.value
        #expect(names(e.model.listing[e.b.id]) == ["b.txt"])
        #expect(names(e.model.listing[e.a.id]) == ["a.txt"])
    }

    @Test func slowOlderListingDoesNotOverwriteNewerForSameDevice() async {
        let e = make()
        let gate = TransferGate()
        e.actionsA.listDirectoryResult = [file("x.txt")]
        e.actionsA.listDirectoryHook = { path in if path == "/sdcard/DCIM" { try? await gate.wait() } }
        let slow = Task { await e.model.open(e.a.id, "/sdcard/DCIM") }
        await until { e.actionsA.calls.count == 1 }
        await e.model.open(e.a.id, "/sdcard/Pictures")
        gate.release()
        await slow.value
        #expect(e.model.currentPath(e.a.id) == "/sdcard/Pictures")
        #expect(e.model.listing[e.a.id] != nil)
        #expect(e.actionsA.calls == ["listDirectory /sdcard/DCIM", "listDirectory /sdcard/Pictures"])
    }

    @Test func revealOpensParent() async {
        let e = make()
        await e.model.reveal(deviceID: e.a.id, path: "/sdcard/Download/a.jpg").value
        #expect(e.model.currentPath(e.a.id) == "/sdcard/Download")
        await e.model.reveal(deviceID: e.a.id, path: "/sdcard/DCIM/Camera/a.jpg").value
        #expect(e.model.currentPath(e.a.id) == "/sdcard/DCIM/Camera")
        #expect(e.actionsA.calls.last == "listDirectory /sdcard/DCIM/Camera")
    }

    private func pushJob(_ e: Env, pushed: [String], state: TransferJob.State? = nil) -> TransferJob {
        var job = TransferJob(
            id: UUID(), deviceID: e.a.id,
            kind: .push(locals: [URL(fileURLWithPath: "/tmp/a.jpg")], dest: "/sdcard/Download/", conflict: .rename, mediaScan: false),
            origin: .workspace, source: .user)
        job.state = state ?? .done(.pushed(pushed))
        return job
    }

    @Test func pushCompletionRefreshesCurrentDir() async {
        let e = make()
        await e.model.open(e.a.id, "/sdcard/Download")
        e.actionsA.listDirectoryResult = [file("a.jpg")]
        e.model.transferFinished(pushJob(e, pushed: ["/sdcard/Download/a.jpg"]))
        await until { e.actionsA.calls.count == 2 }
        await until { names(e.model.listing[e.a.id]) == ["a.jpg"] }
        #expect(names(e.model.listing[e.a.id]) == ["a.jpg"])
    }

    @Test func pushToOtherDirOrFailureDoesNotRefresh() async {
        let e = make()
        await e.model.open(e.a.id, "/sdcard/DCIM")
        e.model.transferFinished(pushJob(e, pushed: ["/sdcard/Download/a.jpg"]))
        e.model.transferFinished(pushJob(e, pushed: [], state: .cancelled))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(e.actionsA.calls.count == 1)
    }

    @Test func pullToTemporaryWritesNamedFileAndLogs() async throws {
        let e = make()
        let url = try await e.commands.pullToTemporary(e.a.id, "/sdcard/Download/x.log")
        #expect(url.lastPathComponent == "x.log")
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(e.actionsA.calls.first?.hasPrefix("pull /sdcard/Download/x.log") == true)
        #expect(e.log.entries.first?.title == "拉取 x.log")
    }

    @Test func pullToTemporaryFailureThrows() async {
        let e = make()
        e.actionsA.errors["pull"] = DeviceError(code: .CONNECTION_FAILED, message: "boom")
        await #expect(throws: DeviceError.self) { _ = try await e.commands.pullToTemporary(e.a.id, "/sdcard/x.log") }
    }
}
