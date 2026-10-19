import AppKit
import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct PasteFlowTests {
    private let dev = DeviceInfo(
        serial: "s1", platform: .android, name: "Pixel", state: .connected, connection: .usb,
        hardwareSerial: "HW1", capabilities: [])

    private struct Env {
        let flow: PasteFlow
        let store: FileTransferStore
        let queue: TransferQueue
        let actions: RecordingActions
        let board: NSPasteboard
        let dir: URL
    }

    private func make(gated: Bool = true, caps: Set<Capability> = [.files, .apps]) -> Env {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flow-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let actions = RecordingActions()
        // 默认让任务停在门口，便于观察入队与临时文件
        if gated { actions.transferGate = TransferGate() }
        let device = DeviceInfo(
            serial: dev.serial, platform: .android, name: dev.name, state: .connected, connection: .usb,
            hardwareSerial: dev.hardwareSerial, capabilities: caps)
        let log = ActivityLog()
        let runner = ActionRunner(log: log)
        let queue = TransferQueue(
            runner: runner, device: { $0 == device.id ? device : nil },
            actions: { $0 == device.id ? actions : nil }, onFinished: { _ in }, progressInterval: .milliseconds(10))
        let mac = MacPasteboard(NSPasteboard(name: .init(UUID().uuidString)))
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let captureStore = CaptureStore(pasteboard: mac, defaults: defaults, home: dir)
        let commands = DeviceCommands(
            runner: runner, store: captureStore, recording: RecordingService(store: captureStore),
            clipboard: ClipboardService(pasteboard: mac, defaults: defaults), toasts: ToastCenter(),
            transfers: queue, device: { $0 == device.id ? device : nil }, session: { _ in nil },
            actions: { $0 == device.id ? actions : nil }, isPopupOpen: { _ in false })
        let store = FileTransferStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, home: dir)
        let board = NSPasteboard(name: .init(UUID().uuidString))
        let flow = PasteFlow(
            deviceID: device.id, commands: commands, store: store, pasteboard: board,
            tempDir: dir.appendingPathComponent("paste"), origin: .popup("HW1"))
        return Env(flow: flow, store: store, queue: queue, actions: actions, board: board, dir: dir)
    }

    private func file(_ name: String, _ e: Env, temporary: Bool = false) -> PasteFile {
        let url = e.dir.appendingPathComponent(name)
        try? Data(repeating: 0x41, count: 4).write(to: url)
        return PasteFile(url: url, name: name, size: 4, format: "X", origin: temporary ? .rawData : .file,
                         isTemporary: temporary)
    }

    private func putFile(_ url: URL, _ e: Env) {
        e.board.clearContents()
        e.board.writeObjects([url as NSURL])
    }

    private func putJPEGData(_ e: Env) {
        e.board.clearContents()
        let item = NSPasteboardItem()
        item.setData(Data([1, 2, 3]), forType: NSPasteboard.PasteboardType("public.jpeg"))
        e.board.writeObjects([item])
    }

    private func until(_ condition: () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    private var choice: PasteChoice {
        PasteChoice(dest: "/sdcard/Pictures/", installAPK: true, mediaScan: true, conflict: .overwrite, heicToJPEG: false)
    }

    @Test func textPastesAsBefore() {
        let e = make()
        e.board.clearContents()
        e.board.setString("hello", forType: .string)
        #expect(e.flow.paste() == .text("hello"))
        #expect(e.flow.pending == nil)
    }

    @Test func emptyBoardDoesNothing() {
        let e = make()
        e.board.clearContents()
        #expect(e.flow.paste() == .nothing)
    }

    @Test func filesNeedConfirmation() {
        let e = make()
        let f = file("a.jpg", e)
        putFile(f.url, e)
        guard case .confirm(let files) = e.flow.paste() else { Issue.record("expected confirm"); return }
        #expect(files.map(\.name) == ["a.jpg"])
        #expect(e.flow.pending?.files.map(\.name) == ["a.jpg"])
        #expect(e.queue.jobs(dev.id).isEmpty)
    }

    @Test func rememberedChoiceSkipsSheet() async {
        let e = make()
        e.store.rememberedPaste = choice
        let f = file("a.jpg", e)
        putFile(f.url, e)
        #expect(e.flow.paste() == .pushedDirectly)
        #expect(e.flow.pending == nil)
        let kinds = e.queue.jobs(dev.id).map(\.kind)
        #expect(kinds == [.push(locals: [f.url], dest: "/sdcard/Pictures/", conflict: .overwrite, mediaScan: true)])
    }

    @Test func confirmRoutesAPK() {
        let e = make()
        let apk = file("app.apk", e), jpg = file("a.jpg", e)
        e.flow.confirm([apk, jpg], choice: choice, remember: false)
        let kinds = e.queue.jobs(dev.id).map(\.kind)
        #expect(kinds.contains(.install(apk: apk.url)))
        #expect(kinds.contains(.push(locals: [jpg.url], dest: "/sdcard/Pictures/", conflict: .overwrite, mediaScan: true)))
    }

    @Test func confirmPushesAPKWhenInstallOff() {
        let e = make()
        let apk = file("app.apk", e)
        var c = choice
        c.installAPK = false
        e.flow.confirm([apk], choice: c, remember: false)
        #expect(e.queue.jobs(dev.id).map(\.kind) == [.push(locals: [apk.url], dest: "/sdcard/Pictures/", conflict: .overwrite, mediaScan: true)])
    }

    @Test func confirmRecordsRecentAndRemembers() {
        let e = make()
        e.flow.confirm([file("a.jpg", e)], choice: choice, remember: true)
        #expect(e.store.recentDirectories == ["/sdcard/Pictures"])
        #expect(e.store.rememberedPaste == choice)
        let e2 = make()
        e2.flow.confirm([file("a.jpg", e2)], choice: choice, remember: false)
        #expect(e2.store.rememberedPaste == nil)
    }

    @Test func cancelDeletesTemporaryFilesOnly() {
        let e = make()
        let temp = file("t.png", e, temporary: true), real = file("r.png", e)
        e.flow.cancel([temp, real])
        #expect(!FileManager.default.fileExists(atPath: temp.url.path))
        #expect(FileManager.default.fileExists(atPath: real.url.path))
    }

    @Test func temporaryFilesDeletedWhenJobFinishes() async {
        let e = make(gated: false)
        let temp = file("t.png", e, temporary: true), real = file("r.png", e)
        e.flow.confirm([temp, real], choice: choice, remember: false)
        await until { e.queue.jobs(dev.id).isEmpty }
        #expect(!FileManager.default.fileExists(atPath: temp.url.path))
        #expect(FileManager.default.fileExists(atPath: real.url.path))
    }

    @Test func pastesGetSeparateDirectories() throws {
        let e = make()
        putJPEGData(e)
        guard case .confirm(let first) = e.flow.paste() else { Issue.record("expected confirm"); return }
        e.flow.cancel(first)
        putJPEGData(e)
        guard case .confirm(let second) = e.flow.paste() else { Issue.record("expected confirm"); return }
        #expect(first[0].url.deletingLastPathComponent() != second[0].url.deletingLastPathComponent())
    }

    @Test func withoutFilesCapabilityNothingHappens() {
        let e = make(caps: [])
        let f = file("a.jpg", e)
        putFile(f.url, e)
        #expect(e.flow.paste() == .nothing)
        #expect(e.flow.pending == nil)
        #expect(e.queue.jobs(dev.id).isEmpty)
    }

    @Test func textIsNotGated() {
        let e = make(caps: [])
        e.board.clearContents()
        e.board.setString("hi", forType: .string)
        #expect(e.flow.paste() == .text("hi"))
    }

    @Test func withoutAppsAPKIsPushedPlain() {
        let e = make(caps: [.files])
        #expect(!e.flow.canInstall)
        let apk = file("app.apk", e)
        e.store.rememberedPaste = choice  // installAPK == true
        putFile(apk.url, e)
        #expect(e.flow.paste() == .pushedDirectly)
        #expect(e.queue.jobs(dev.id).map(\.kind) == [.push(locals: [apk.url], dest: "/sdcard/Pictures/", conflict: .overwrite, mediaScan: true)])
    }

    @Test func withoutFilesOnlyAPKsAreInstalled() {
        let e = make(caps: [.apps])
        let apk = file("app.apk", e), jpg = file("a.jpg", e)
        e.board.clearContents()
        e.board.writeObjects([apk.url as NSURL, jpg.url as NSURL])
        guard case .confirm(let files) = e.flow.paste() else { Issue.record("expected confirm"); return }
        #expect(files.map(\.name) == ["app.apk"])
        var c = choice
        c.installAPK = false
        e.flow.confirm(files, choice: c, remember: false)
        #expect(e.queue.jobs(dev.id).map(\.kind) == [.install(apk: apk.url)])
    }

    @Test func textAndEmptyPastesLeaveNoTempDirectory() {
        let e = make()
        e.board.clearContents()
        e.board.setString("hi", forType: .string)
        _ = e.flow.paste()
        e.board.clearContents()
        _ = e.flow.paste()
        let paste = e.dir.appendingPathComponent("paste")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: paste.path)) ?? []).isEmpty)
    }
}
