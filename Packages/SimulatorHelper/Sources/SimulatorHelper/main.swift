import Foundation
import Darwin
import CoreGraphics
import CoreImage
import IOSurface
import FBControlCore
import FBSimulatorControl
import FBSimulatorAX
import FBVideoCore

@MainActor
final class Output {
    func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(10)
        do { try FileHandle.standardOutput.write(contentsOf: data) }
        catch { Darwin.exit(0) }
    }
    func failure(_ error: Error, id: Int? = nil) {
        let failure = error as? HelperFailure ?? .init(code: "CONNECTION_FAILED", message: error.localizedDescription)
        var response: [String: Any] = ["ok": false, "code": failure.code, "error": failure.message]
        if let id { response["id"] = id } else { response["event"] = "error" }
        send(response)
    }
}

// One blocking reader runs away from the main actor: CoreSimulator uses the main dispatch queue.
func inputLines() -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream { continuation in
        let task = Task.detached {
            do {
                var framer = LineFramer()
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                while true {
                    let count = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                    if count == 0 { break }
                    if count < 0 {
                        if errno == EINTR { continue }
                        throw HelperFailure(code: "CONNECTION_FAILED", message: "Could not read helper input")
                    }
                    for line in try framer.append(Data(buffer.prefix(count))) { continuation.yield(line) }
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

func xcrun(_ arguments: [String], input: String? = nil) async throws -> String {
    try await Task.detached {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        let output = Pipe()
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: timeout)
        defer { timeout.cancel() }
        if let input { try stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8)) }
        try stdin.fileHandleForWriting.close()
        let data = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw HelperFailure(code: process.terminationReason == .uncaughtSignal ? "TIMEOUT" : "CONNECTION_FAILED", message: "xcrun \(arguments.first ?? "") failed (\(process.terminationStatus))")
        }
        return String(decoding: data, as: UTF8.self)
    }.value
}

func simctl(_ arguments: [String], input: String? = nil) async throws -> String {
    try await xcrun(["simctl"] + arguments, input: input)
}

@MainActor
final class SimulatorController {
    let simulator: Simulator
    let session: SimulatorHIDSession
    private let textInput = GuestTextInput()
    private var textStartup: Task<Void, Error>?
    let output: Output
    let framebuffer: Framebuffer
    private let displayAttachment: FramebufferAttachment
    private var displayWatch: Task<Void, Never>?
    private var renderedFrameCount: UInt = 0
    private var video: SimulatorPreviewEncoder?
    private var surface: IOSurface?
    private var geometry: SimulatorDisplayGeometry?
    private var displayConfiguration: SimulatorDisplayConfiguration?
    private var videoConsumer: SimulatorVideoConsumer?
    private var touch = TouchDeliveryState()
    private var humanTouchStream: AcknowledgedEventStream<SimulatorHIDEvent>?
    private var humanTouchSize: CGSize?
    private var nativeTouchPoint: CGPoint?
    private var eventsTask: Task<Void, Never>?
    private var framesTask: Task<Void, Never>?
    private var closed = false

    init(simulator: Simulator, output: Output) async throws {
        self.simulator = simulator
        self.output = output
        session = try await SimulatorHIDSession.open(simulator)
        framebuffer = try await simulator.framebuffer.connect()
        displayAttachment = try framebuffer.attach()
        surface = displayAttachment.initialSurface
        displayConfiguration = displayAttachment.initialConfiguration
        if let configuration = displayAttachment.initialConfiguration {
            if case let .transitioning(incoming) = configuration.phase {
                geometry = incoming?.geometry
            } else { geometry = try? configuration.activeGeometry() }
        }
        textStartup = Task { [textInput, udid = simulator.udid] in
            try await textInput.start(simulatorUDID: udid)
        }
    }

    func startFrames() {
        displayWatch = Task { [weak self, displayAttachment] in
            for await event in displayAttachment.events {
                guard let self, !self.closed else { return }
                switch event {
                case .frameRendered:
                    self.renderedFrameCount += 1
                    if let surface = self.surface { self.video?.submit(surface: surface, geometry: self.geometry) }
                case let .surfaceChanged(surface):
                    self.surface = surface
                    if let surface { self.video?.submit(surface: surface, geometry: self.geometry) }
                case let .configurationChanged(configuration):
                    let changed = self.touch.observeDisplayChange(
                        from: self.displayConfiguration?.generation, to: configuration.generation)
                    self.displayConfiguration = configuration
                    if case let .transitioning(incoming) = configuration.phase {
                        if let incoming { self.geometry = incoming.geometry }
                    } else if let geometry = try? configuration.activeGeometry() {
                        self.geometry = geometry
                    }
                    if let surface = self.surface { self.video?.submit(surface: surface, geometry: self.geometry) }
                    if changed, self.humanTouchStream != nil {
                        // The native stream releases contacts on its original display.
                        // A changed binding must never replay an uncertain touch.
                        try? await self.finishHumanTouchStream(cancel: true)
                    }
                case let .ended(error):
                    self.output.failure(error)
                    await self.close()
                    Darwin.exit(1)
                default: break
                }
            }
        }
        eventsTask = Task(priority: .high) { [weak self] in
            guard let self else { return }
            do {
                let consumer = try SimulatorVideoConsumer()
                self.videoConsumer = consumer
                let video = SimulatorPreviewEncoder(consumer: consumer, logger: simulator.logger) { [weak self] error in
                    Task { @MainActor in
                        guard let self, !self.closed else { return }
                        self.output.failure(error)
                        await self.close()
                        Darwin.exit(1)
                    }
                }
                self.video = video
                if let surface { video.submit(surface: surface, geometry: geometry) }
            } catch {
                guard !self.closed else { return }
                self.output.failure(error)
                await self.close()
                Darwin.exit(1)
            }
        }
        framesTask = Task { [weak self] in
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self, !self.closed else { return }
                if self.simulator.state != .booted {
                    self.output.failure(HelperFailure(code: "CONNECTION_FAILED", message: "模拟器已停止运行"))
                    await self.close()
                    Darwin.exit(1)
                }
                if .now > deadline, self.videoConsumer?.hasFrame != true {
                    self.output.failure(HelperFailure(code: "TIMEOUT", message: "未收到模拟器画面。请关闭这个设备的 Simulator/DeviceHub 窗口后重新连接；其他设备窗口可以保留。"))
                    await self.close()
                    Darwin.exit(1)
                }
            }
        }
    }

    func handle(_ request: Request) async throws -> Bool {
        var response: [String: Any] = ["id": request.id, "ok": true]
        switch request.command {
        case "video_stats":
            if let video {
                var stats = video.statistics
                stats["rendered"] = renderedFrameCount
                response["stats"] = stats
            }
        case "touch":
            let humanDragRelease = request.phase == "up" && touch.owner == "finger" && touch.hasMoved
            let pending = try touch.prepare(request)
            try validateTouch(pending)
            let phase = pending.phase
            let point = pending.point
            let size: CGSize
            if request.pointer == "finger" {
                if humanTouchStream == nil {
                    let configuration: SimulatorDisplayConfiguration
                    if let cached = displayConfiguration {
                        configuration = cached
                    } else {
                        configuration = try await simulator.displays.configuration()
                        displayConfiguration = configuration
                    }
                    try validateTouch(pending)
                    size = try configuration.activeGeometry().pointSize
                    let hid = session.hid
                    let logger = simulator.logger
                    let binding = DisplaySelection.configuration(generation: configuration.generation)
                    humanTouchSize = size
                    humanTouchStream = AcknowledgedEventStream { events in
                        try await hid.send(events: events, logger: logger, on: binding)
                    }
                } else {
                    size = humanTouchSize!
                }
            } else {
                try await finishHumanTouchStream()
                let configuration = try await simulator.displays.configuration()
                size = try configuration.activeGeometry().pointSize
            }
            try validateTouch(pending)
            let nativePoint = CGPoint(x: point.x * size.width, y: point.y * size.height)
            let event = SimulatorHIDEvent.touch(direction: phase == "up" ? .up : .down, x: nativePoint.x, y: nativePoint.y)
            if let stream = humanTouchStream {
                do {
                    try await stream.send(event)
                    try validateTouch(pending)
                    if phase == "up", !humanDragRelease {
                        // A tap settles before a following focus-dependent text command.
                        try await finishHumanTouchStream()
                    }
                } catch {
                    try? await finishHumanTouchStream(cancel: true)
                    throw error
                }
            } else {
                let drain: SimulatorHIDDrain = phase == "up" ? .perEvent : .onClose
                try await session.hid.send(event: event, logger: simulator.logger, drain: drain)
            }
            try validateTouch(pending)
            try touch.commit(pending)
            nativeTouchPoint = phase == "up" ? nil : nativePoint
        case "key":
            guard let key = request.key else { throw HelperFailure.invalid("key is required") }
            let event: SimulatorHIDEvent
            if key == "home" {
                event = .shortButtonPress(.homeButton)
            } else {
                let keys: [String: UInt32] = ["enter": 0x28, "delete": 0x2A, "forwardDelete": 0x4C, "tab": 0x2B, "right": 0x4F, "left": 0x50, "down": 0x51, "up": 0x52]
                guard let usage = keys[key] else { throw HelperFailure(code: "UNSUPPORTED", message: "Unsupported simulator key: \(key)") }
                event = .shortKeyPress(usage)
            }
            try await finishHumanTouchStream(cancel: touch.owner == "finger")
            try await session.hid.send(event: event, logger: simulator.logger)
        case "clipboard_get":
            response["text"] = try await clipboardRead()
        case "clipboard_set", "text":
            guard let text = request.text else { throw HelperFailure.invalid("text is required") }
            let shouldPaste = request.command == "text" || request.paste == true
            if shouldPaste, touch.owner != nil { throw HelperFailure(code: "AI_LOCKED", message: "Release the active touch before typing text") }
            if shouldPaste { try await finishHumanTouchStream() }
            if request.command == "clipboard_set" {
                let lease = try await ClipboardLease.acquire()
                defer { withExtendedLifetime(lease) {} }
                try await clipboardWrite(text)
                if request.paste == true { try await insertText(text, clipboardLeased: true) }
            } else {
                try await insertText(text, clipboardLeased: false)
            }
        case "quit":
            await close()
            output.send(response)
            return false
        default: throw HelperFailure(code: "UNSUPPORTED", message: "Unsupported helper command: \(request.command)")
        }
        output.send(response)
        return true
    }

    private func validateTouch(_ pending: TouchDeliveryState.Pending) throws {
        guard !closed else { throw HelperFailure(code: "CONNECTION_FAILED", message: "Simulator input is closed") }
        try touch.validate(pending)
    }

    private func finishHumanTouchStream(cancel: Bool = false) async throws {
        if cancel {
            let humanOwned = touch.owner == "finger"
            touch.invalidateHuman()
            if humanOwned { nativeTouchPoint = nil }
        }
        guard let stream = humanTouchStream else { return }
        // Retire shared state before suspension. Old cleanup must not clear a newer
        // display's stream/contact after its own operation has released the lease.
        humanTouchStream = nil
        humanTouchSize = nil
        nativeTouchPoint = nil
        if cancel { await stream.cancel() }
        else { try await stream.finish() }
    }

    private func requestText(command: String, text: String? = nil, paste: Bool = false) async throws -> GuestTextResponse {
        try await textStartup?.value
        return try await textInput.request(command: command, text: text, paste: paste)
    }

    private func insertText(_ text: String, clipboardLeased: Bool) async throws {
        do { _ = try await requestText(command: "text", text: text) }
        catch let failure as HelperFailure where failure.code == "NATIVE_PASTE_REQUIRED" {
            // The guest guarantees this response precedes every edit. All uncertain
            // delivery errors propagate without falling back or replaying text.
            let lease = clipboardLeased ? nil : try await ClipboardLease.acquire()
            defer { withExtendedLifetime(lease) {} }
            try await clipboardWrite(text)
            if !text.isEmpty { try await pasteSecureText(expectedClipboard: text) }
        }
    }

    private func clipboardBackend() async throws -> [String] {
        let state = try? await simctl(["spawn", simulator.udid, "notifyutil", "-g", "com.apple.coredevice.pasteboard.active"])
        if state?.split(whereSeparator: \.isWhitespace).last == "0" { return ["simctl"] }
        return ["devicectl", "device", "pasteboard"]
    }

    private func clipboardRead() async throws -> String {
        let backend = try await clipboardBackend()
        if backend == ["simctl"] { return try await simctl(["pbpaste", simulator.udid]) }
        return try await xcrun(["devicectl", "device", "pasteboard", "paste", "--device", simulator.udid, "--timeout", "8", "--quiet"])
    }

    private func clipboardWrite(_ text: String) async throws {
        let backend = try await clipboardBackend()
        if backend == ["simctl"] { _ = try await simctl(["pbcopy", simulator.udid], input: text) }
        else { _ = try await xcrun(["devicectl", "device", "pasteboard", "copy", "--device", simulator.udid, "--timeout", "8", "--quiet"], input: text) }
        guard try await clipboardRead() == text else {
            throw HelperFailure(code: "CONNECTION_FAILED", message: "Clipboard changed before delivery; no paste was sent")
        }
    }

    private func pasteSecureText(expectedClipboard: String) async throws {
        var baseline = try await readMenu(simulator)
        if baseline.contains(where: { $0.isNativeMenu && PasteMenu.labels.contains($0.label) }) {
            try await session.hid.send(event: .shortKeyPress(0x29), logger: simulator.logger)
            try await Task.sleep(for: .milliseconds(350))
            baseline = try await readMenu(simulator)
            guard !baseline.contains(where: { $0.isNativeMenu && PasteMenu.labels.contains($0.label) }) else {
                throw HelperFailure.invalid("Close the existing edit menu and focus the text field before retrying")
            }
        }
        try await session.hid.send(event: .shortKeyPress(101), logger: simulator.logger)
        var menu = PasteMenu()
        let openedAt = ContinuousClock.now
        let deadline = openedAt.advanced(by: .seconds(5))
        var retriedOpening = false
        var target: MenuItem?
        while .now < deadline {
            let items = try await readMenu(simulator)
            if let ready = menu.observe(items, baseline: baseline, at: .now) { target = ready; break }
            if !retriedOpening, openedAt.duration(to: .now) > .seconds(2),
               !items.contains(where: { PasteMenu.labels.contains($0.label) }) {
                try await session.hid.send(event: .shortKeyPress(101), logger: simulator.logger)
                retriedOpening = true
            }
            try await Task.sleep(for: .milliseconds(120))
        }
        guard let target else { throw HelperFailure(code: "UNSUPPORTED", message: "The focused control did not expose a stable native Paste action") }
        guard try await clipboardRead() == expectedClipboard else {
            throw HelperFailure(code: "CONNECTION_FAILED", message: "Clipboard changed before delivery; no paste was sent")
        }
        let point = CGPoint(x: target.frame.midX, y: target.frame.midY)
        nativeTouchPoint = point
        do {
            try await session.hid.send(event: .touch(direction: .down, x: point.x, y: point.y), logger: simulator.logger)
            try await Task.sleep(for: .milliseconds(50))
            try await session.hid.send(event: .touch(direction: .up, x: point.x, y: point.y), logger: simulator.logger)
            nativeTouchPoint = nil
        } catch {
            try? await session.hid.send(event: .touch(direction: .up, x: point.x, y: point.y), logger: simulator.logger)
            nativeTouchPoint = nil
            throw HelperFailure(code: "CONNECTION_FAILED", message: "Paste delivery was interrupted; verify the field before retrying")
        }
        let completionDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        var absentSince: ContinuousClock.Instant?
        while .now < completionDeadline {
            let visible = try await readMenu(simulator).contains { $0.isNativeMenu && PasteMenu.labels.contains($0.label) }
            if visible { absentSince = nil }
            else if let absentSince, absentSince.duration(to: .now) >= .milliseconds(300) { return }
            else if absentSince == nil { absentSince = .now }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HelperFailure(code: "TIMEOUT", message: "Paste was sent but the menu did not close; verify the field before retrying")
    }

    func close() async {
        guard !closed else { return }
        closed = true
        try? await finishHumanTouchStream(cancel: true)
        if let point = nativeTouchPoint {
            try? await session.hid.send(event: .touch(direction: .up, x: point.x, y: point.y), logger: simulator.logger)
        }
        nativeTouchPoint = nil
        textStartup?.cancel()
        _ = try? await textStartup?.value
        await textInput.close()
        eventsTask?.cancel()
        framesTask?.cancel()
        displayWatch?.cancel()
        displayAttachment.cancel()
        videoConsumer?.close()
        await video?.close()
        video = nil
        videoConsumer = nil
        await session.close()
    }
}

@main struct SimulatorHelperMain {
    @MainActor static func main() async {
        let output = Output()
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Interactive simulator video and input")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        // Ignore SIGPIPE so a detached viewer simply causes the next write to fail.
        signal(SIGPIPE, SIG_IGN)
        do {
            let args = CommandLine.arguments
            guard args.count == 3, args[1] == "--udid", UUID(uuidString: args[2]) != nil else {
                throw HelperFailure.invalid("Usage: tandem-simulator --udid <UUID>")
            }
            let bootstrap = try SimulatorControlBootstrap(configuration: .init(deviceSetPath: nil, logger: nil))
            guard let simulator = bootstrap.set.simulator(withUDID: args[2]) else { throw HelperFailure.invalid("Simulator UDID was not found") }
            guard simulator.state == .booted else { throw HelperFailure(code: "CONNECTION_FAILED", message: "Simulator must be booted before connecting") }
            let controller = try await SimulatorController(simulator: simulator, output: output)
            signal(SIGTERM, SIG_IGN)
            signal(SIGINT, SIG_IGN)
            let signals = [SIGTERM, SIGINT].map { number in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
                source.setEventHandler { Task { @MainActor in await controller.close(); Darwin.exit(0) } }
                source.resume()
                return source
            }
            defer { signals.forEach { $0.cancel() } }
            controller.startFrames()
            output.send(["event": "ready"])
            do {
                for try await line in inputLines() {
                    let request: Request
                    do { request = try JSONDecoder().decode(Request.self, from: line) }
                    catch {
                        let id = (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["id"] as? Int
                        output.failure(HelperFailure.invalid("Malformed JSON request"), id: id)
                        continue
                    }
                    do { let keepReading = try await controller.handle(request); if !keepReading { break } }
                    catch { output.failure(error, id: request.id) }
                }
            } catch { output.failure(error) }
            await controller.close()
        } catch { output.failure(error); Darwin.exit(1) }
    }
}
