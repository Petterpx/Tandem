import AppKit
import Darwin

// This diagnostic app deliberately has no dependency on Tandem targets.
struct Options {
    var backend = ""
    var udid = ""
    var ffmpeg = "/opt/homebrew/bin/ffmpeg"
    var metrics: String?
    var selfTest = false

    init(_ args: [String]) throws {
        var index = 0
        while index < args.count {
            let key = args[index]
            if key == "--self-test" { selfTest = true; index += 1; continue }
            guard index + 1 < args.count else { throw ProbeError.message("Missing value for \(key)") }
            let value = args[index + 1]
            switch key {
            case "--backend": backend = value
            case "--udid": udid = value
            case "--ffmpeg": ffmpeg = value
            case "--metrics": metrics = value
            default: throw ProbeError.message("Unknown option: \(key)")
            }
            index += 2
        }
        if !selfTest {
            guard backend.hasPrefix("/"), !udid.isEmpty, ffmpeg.hasPrefix("/") else {
                throw ProbeError.message("Usage: TandemUSBProbe --backend /absolute/backend --udid DEVICE [--ffmpeg /absolute/ffmpeg] [--metrics /absolute/events.ndjson]")
            }
            for path in [backend, ffmpeg] where !FileManager.default.isExecutableFile(atPath: path) {
                throw ProbeError.message("Not executable: \(path)")
            }
            if let metrics, !metrics.hasPrefix("/") { throw ProbeError.message("--metrics must be an absolute path") }
        }
    }
}

enum ProbeError: Error, CustomStringConvertible {
    case message(String)
    var description: String { switch self { case let .message(value): return value } }
}

/// Incremental image2pipe parser. JPEG markers can span arbitrary read boundaries.
struct JPEGParser {
    private var bytes = Data()
    private var scan = 2
    private let start = Data([0xff, 0xd8])
    private let end = Data([0xff, 0xd9])
    mutating func append(_ data: Data) -> [Data] {
        bytes.append(data)
        var images: [Data] = []
        while true {
            guard let first = bytes.range(of: start) else {
                bytes = bytes.last == 0xff ? Data([0xff]) : Data()
                scan = 2
                break
            }
            if first.lowerBound != bytes.startIndex {
                bytes = Data(bytes[first.lowerBound...]); scan = 2
            }
            let from = min(max(2, scan), bytes.count)
            guard let last = bytes.range(of: end, in: from..<bytes.count) else {
                scan = max(2, bytes.count - 1)
                // A corrupt/unbounded frame must not consume memory indefinitely.
                if bytes.count > 32 * 1024 * 1024 { bytes.removeAll(keepingCapacity: false); scan = 2 }
                break
            }
            images.append(Data(bytes[..<last.upperBound]))
            bytes = Data(bytes[last.upperBound...]); scan = 2
        }
        return images
    }
}

func imageRectangle(in bounds: NSRect, size: NSSize) -> NSRect {
    guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
    let scale = min(bounds.width / size.width, bounds.height / size.height)
    let width = size.width * scale, height = size.height * scale
    return NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
}

func normalized(_ point: NSPoint, in rect: NSRect) -> NSPoint? {
    guard rect.width > 0, rect.height > 0 else { return nil }
    return NSPoint(x: min(1, max(0, (point.x - rect.minX) / rect.width)),
                   y: min(1, max(0, (point.y - rect.minY) / rect.height)))
}

/// A single background writer preserves transitions and replaces only adjacent queued moves.
final class CommandWriter {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "usb-probe.control")
    private var pending: [(Data, Bool)] = []
    private var draining = false
    private var closed = false
    private let handle: FileHandle
    private let onError: (String) -> Void
    init(_ handle: FileHandle, onError: @escaping (String) -> Void) {
        self.handle = handle; self.onError = onError
    }
    func send(_ object: [String: Any], move: Bool = false) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        lock.lock()
        guard !closed else { lock.unlock(); return }
        if move, pending.last?.1 == true { pending[pending.count - 1] = (data, true) }
        else { pending.append((data, move)) }
        let start = !draining
        draining = true
        lock.unlock()
        if start { queue.async { self.drain() } }
    }
    private func drain() {
        while true {
            lock.lock()
            guard !pending.isEmpty else {
                draining = false
                let shouldClose = closed
                lock.unlock()
                if shouldClose { try? handle.close() }
                return
            }
            let item = pending.removeFirst()
            lock.unlock()
            do { try handle.write(contentsOf: item.0) }
            catch {
                lock.lock(); pending.removeAll(); closed = true; draining = false; lock.unlock()
                try? handle.close()
                onError("Control pipe: \(error.localizedDescription)")
                return
            }
        }
    }
    func closeAfterPending() {
        lock.lock(); closed = true; let idle = !draining; lock.unlock()
        if idle { queue.async { try? self.handle.close() } }
    }
}

final class Pipeline {
    private let backend = Process()
    private let decoder = Process()
    private let control = Pipe(), video = Pipe(), pictures = Pipe(), backendErrors = Pipe(), decoderErrors = Pipe()
    private let io = DispatchQueue(label: "usb-probe.decode")
    private let metricsQueue = DispatchQueue(label: "usb-probe.metrics")
    private var metricsHandle: FileHandle?
    private var parser = JPEGParser()
    private var lines: [String: Data] = [:]
    private var writer: CommandWriter?
    private let frameLock = NSLock()
    private var latestFrame: Data?
    private var deliveryPending = false
    private var totalFrames = 0
    private var stopped = false
    private var shutdownTimer: DispatchSourceTimer?
    private var shutdownCallbacks: [() -> Void] = []
    var onFrame: ((Data, Int) -> Void)?
    var onEvent: ((String, [String: Any]?) -> Void)?

    func start(_ options: Options) throws {
        if let path = options.metrics {
            if !FileManager.default.fileExists(atPath: path) {
                guard FileManager.default.createFile(atPath: path, contents: nil) else { throw ProbeError.message("Cannot create metrics file") }
            }
            metricsHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            try metricsHandle?.seekToEnd()
        }
        backend.executableURL = URL(fileURLWithPath: options.backend)
        backend.arguments = ["--udid", options.udid]
        backend.standardInput = control
        backend.standardOutput = video
        backend.standardError = backendErrors
        decoder.executableURL = URL(fileURLWithPath: options.ffmpeg)
        // nobuffer discards the probing keyframe; retain it while minimizing probing instead.
        decoder.arguments = ["-hide_banner", "-loglevel", "warning", "-flags", "low_delay",
                             "-probesize", "32", "-analyzeduration", "1", "-threads", "2", "-f", "hevc", "-i", "pipe:0",
                             "-an", "-fps_mode", "passthrough", "-c:v", "mjpeg", "-threads", "2", "-q:v", "5",
                             "-f", "image2pipe", "-flush_packets", "1", "pipe:1"]
        decoder.standardInput = video
        decoder.standardOutput = pictures
        decoder.standardError = decoderErrors
        writer = CommandWriter(control.fileHandleForWriting) { [weak self] text in self?.event(text) }
        backend.terminationHandler = { [weak self] process in self?.event("Backend exited (\(process.terminationStatus))") }
        decoder.terminationHandler = { [weak self] process in self?.event("Decoder exited (\(process.terminationStatus))") }
        read(pictures.fileHandleForReading) { [weak self] data in self?.receivePictures(data) }
        read(backendErrors.fileHandleForReading) { [weak self] data in self?.receiveLines(data, source: "backend") }
        read(decoderErrors.fileHandleForReading) { [weak self] data in self?.receiveLines(data, source: "ffmpeg") }
        do {
            try decoder.run()
            try backend.run()
        } catch {
            stop()
            throw error
        }
        // Parent-side copies otherwise keep the pipes open after a child exits.
        try? control.fileHandleForReading.close()
        try? video.fileHandleForReading.close()
        try? video.fileHandleForWriting.close()
        try? pictures.fileHandleForWriting.close()
        try? backendErrors.fileHandleForWriting.close()
        try? decoderErrors.fileHandleForWriting.close()
        event("Waiting for HEVC video; View Only enabled")
    }
    private func read(_ handle: FileHandle, consume: @escaping (Data) -> Void) {
        handle.readabilityHandler = { [weak self] file in
            let data = file.availableData
            if data.isEmpty { file.readabilityHandler = nil }
            self?.io.async { consume(data) }
        }
    }
    private func receivePictures(_ data: Data) {
        let frames = parser.append(data)
        guard let newest = frames.last else { return }
        frameLock.lock()
        totalFrames += frames.count
        latestFrame = newest
        let schedule = !deliveryPending
        deliveryPending = true
        frameLock.unlock()
        if schedule {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.frameLock.lock()
                let data = self.latestFrame, count = self.totalFrames
                self.latestFrame = nil; self.deliveryPending = false
                self.frameLock.unlock()
                if let data { self.onFrame?(data, count) }
            }
        }
    }
    private func receiveLines(_ data: Data, source: String) {
        var buffer = lines[source] ?? Data()
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0a) {
            let line = Data(buffer[..<newline]); buffer = Data(buffer[buffer.index(after: newline)...])
            emitLine(line, source: source)
        }
        if data.isEmpty, !buffer.isEmpty { emitLine(buffer, source: source); buffer.removeAll() }
        if buffer.count > 1024 * 1024 { buffer.removeAll(); event("Discarded oversized \(source) diagnostic line") }
        lines[source] = buffer
    }
    private func emitLine(_ data: Data, source: String) {
        let text = String(decoding: data, as: UTF8.self)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        record(["source": source, "message": text])
        DispatchQueue.main.async { [weak self] in self?.onEvent?("\(source): \(text.prefix(240))", object) }
    }
    private func event(_ text: String) {
        record(["source": "viewer", "message": text])
        DispatchQueue.main.async { [weak self] in self?.onEvent?(text, nil) }
    }
    private func record(_ object: [String: Any]) {
        guard let handle = metricsHandle else { return }
        var value = object
        value["viewer_timestamp"] = Date().timeIntervalSince1970
        guard var data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        data.append(0x0a)
        metricsQueue.async { try? handle.write(contentsOf: data) }
    }
    func send(_ object: [String: Any], move: Bool = false) { writer?.send(object, move: move) }
    func recordMetrics(_ object: [String: Any]) {
        var value = object; value["source"] = "viewer"; value["event"] = "metrics"
        record(value)
    }
    func stop(completion: (() -> Void)? = nil) {
        if let completion { shutdownCallbacks.append(completion) }
        guard !stopped else {
            if shutdownTimer == nil { finishShutdown() }
            return
        }
        stopped = true
        writer?.send(["op": "stop"])
        writer?.closeAfterPending()
        let processes = [backend, decoder]
        DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) {
            for process in processes where process.isRunning { process.terminate() }
        }
        // Allow the backend's bounded input/video/writer/media cleanup even if
        // SIGTERM at t=3 is what starts it; never cut off a pending touch release.
        DispatchQueue.global().asyncAfter(deadline: .now() + 20.0) {
            for process in processes where process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        shutdownTimer = timer
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if processes.allSatisfy({ !$0.isRunning }) { self.finishShutdown() }
        }
        timer.resume()
    }
    private func finishShutdown() {
        shutdownTimer?.cancel(); shutdownTimer = nil
        let callbacks = shutdownCallbacks; shutdownCallbacks.removeAll()
        for callback in callbacks { callback() }
    }
}

final class VideoView: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    var inputEnabled = false { didSet { if !inputEnabled { releaseTouch() } } }
    var touch: ((String, NSPoint) -> Void)?
    private var activePoint: NSPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var imageRect: NSRect { imageRectangle(in: bounds, size: image?.size ?? .zero) }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        image?.draw(in: imageRect, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        if image == nil {
            let text = "Waiting for USB video…" as NSString
            text.draw(at: NSPoint(x: 20, y: 20), withAttributes: [.foregroundColor: NSColor.lightGray, .font: NSFont.systemFont(ofSize: 15)])
        }
    }
    override func mouseDown(with event: NSEvent) {
        guard inputEnabled, image != nil, window?.isKeyWindow == true else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard imageRect.contains(point), let mapped = normalized(point, in: imageRect) else { return }
        releaseTouch()
        activePoint = mapped; touch?("down", mapped)
    }
    override func mouseDragged(with event: NSEvent) { moveTouch(event) }
    override func mouseMoved(with event: NSEvent) { moveTouch(event) }
    private func moveTouch(_ event: NSEvent) {
        guard inputEnabled, activePoint != nil,
              let mapped = normalized(convert(event.locationInWindow, from: nil), in: imageRect) else { return }
        activePoint = mapped; touch?("move", mapped)
    }
    override func mouseUp(with event: NSEvent) {
        guard activePoint != nil else { return }
        if let mapped = normalized(convert(event.locationInWindow, from: nil), in: imageRect) { activePoint = mapped }
        releaseTouch()
    }
    func releaseTouch() {
        guard let point = activePoint else { return }
        activePoint = nil; touch?("up", point)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let options: Options
    private let pipeline = Pipeline()
    private var window: NSWindow!
    private let video = VideoView()
    private let status = NSTextField(labelWithString: "Starting USB backend…")
    private let counters = NSTextField(labelWithString: "FPS 0.0 · Frames 0 · ACK 0 · Sent 0")
    private let viewOnly = NSButton(checkboxWithTitle: "View Only", target: nil, action: nil)
    private let home = NSButton(title: "Home", target: nil, action: nil)
    private var timer: Timer?
    private var frameCount = 0, lastFrames = 0, viewUpdates = 0, lastViewUpdates = 0, ackCount = 0, commandID = 0
    private var ackLatency: Double?
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var terminating = false
    private var operational = true
    init(_ options: Options) { self.options = options }
    func applicationDidFinishLaunching(_ notification: Notification) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 820),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Tandem USB Probe"
        window.minSize = NSSize(width: 360, height: 400)
        window.delegate = self
        let root = NSView(); window.contentView = root
        let controls = NSStackView(views: [viewOnly, home])
        controls.orientation = .horizontal; controls.spacing = 20
        viewOnly.state = .on; viewOnly.target = self; viewOnly.action = #selector(toggleInput)
        home.target = self; home.action = #selector(goHome); home.isEnabled = false
        counters.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        status.font = .systemFont(ofSize: 11)
        status.lineBreakMode = .byTruncatingTail
        status.setAccessibilityLabel("USB backend status")
        counters.setAccessibilityLabel("Video and control metrics")
        video.setAccessibilityElement(true); video.setAccessibilityLabel("USB device screen")
        video.setAccessibilityRole(.image)
        for view in [video, controls, counters, status] {
            view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            video.topAnchor.constraint(equalTo: root.topAnchor), video.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: root.trailingAnchor), video.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -10),
            controls.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), controls.heightAnchor.constraint(equalToConstant: 26),
            counters.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 5), counters.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            counters.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            status.topAnchor.constraint(equalTo: counters.bottomAnchor, constant: 4), status.leadingAnchor.constraint(equalTo: counters.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: counters.trailingAnchor), status.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])
        video.touch = { [weak self] phase, point in
            self?.send(["op": "touch", "phase": phase, "x": point.x, "y": point.y], move: phase == "move")
        }
        pipeline.onFrame = { [weak self] data, count in
            guard let self, !self.terminating, let image = NSImage(data: data), image.size.width > 0 else { return }
            self.video.image = image; self.frameCount = count; self.viewUpdates += 1
            self.updateInput()
        }
        pipeline.onEvent = { [weak self] text, object in
            guard let self else { return }
            self.status.stringValue = text
            if let object {
                let kind = (object["event"] ?? object["type"] ?? object["op"]) as? String ?? ""
                if kind == "ack" || kind == "input_ack" || (object["id"] != nil && (object["ok"] != nil || object["error"] != nil || object["result"] != nil)) {
                    self.ackCount += 1
                    self.ackLatency = (object["latency_ms"] as? NSNumber)?.doubleValue
                }
            }
            if text.contains("exited") || text.hasPrefix("Control pipe:") {
                self.operational = false
                self.video.inputEnabled = false; self.viewOnly.state = .on; self.home.isEnabled = false
                self.pipeline.stop()
            }
        }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        do { try pipeline.start(options) }
        catch { operational = false; status.stringValue = "Start failed: \(error)"; pipeline.stop() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateMetrics() }
    }
    private func send(_ object: [String: Any], move: Bool = false) {
        commandID += 1
        var command = object; command["id"] = commandID
        pipeline.send(command, move: move)
    }
    private func updateInput() {
        let enabled = viewOnly.state == .off && video.image != nil && !terminating && operational
        video.inputEnabled = enabled; home.isEnabled = enabled
        video.setAccessibilityValue(enabled ? "Live touch input enabled" : "View only; touch input disabled")
    }
    @objc private func toggleInput() { updateInput() }
    @objc private func goHome() { guard home.isEnabled else { return }; send(["op": "button", "button": "home"]) }
    private func updateMetrics() {
        let now = ProcessInfo.processInfo.systemUptime, duration = max(0.001, now - lastTick)
        counters.stringValue = String(format: "FPS %.1f · View updates %.1f/s · Frames %d · ACK %d · Sent %d", Double(frameCount - lastFrames) / duration, Double(viewUpdates - lastViewUpdates) / duration, frameCount, ackCount, commandID)
        if let latency = ackLatency { counters.stringValue += String(format: " · %.1f ms", latency) }
        var metrics: [String: Any] = ["fps": Double(frameCount - lastFrames) / duration,
                                "view_updates_per_second": Double(viewUpdates - lastViewUpdates) / duration,
                                "frames": frameCount, "acks": ackCount, "sent": commandID]
        if let latency = ackLatency { metrics["last_ack_latency_ms"] = latency }
        pipeline.recordMetrics(metrics)
        lastFrames = frameCount; lastViewUpdates = viewUpdates; lastTick = now
    }
    func windowDidResignKey(_ notification: Notification) { video.releaseTouch() }
    func applicationDidResignActive(_ notification: Notification) { video.releaseTouch() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true; timer?.invalidate(); video.releaseTouch()
        pipeline.stop { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

func selfTest() throws {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw ProbeError.message("Self-test failed: \(message)") }
    }
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 8, bitsPerSample: 8,
                                  samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    memset(bitmap.bitmapData!, 180, bitmap.bytesPerRow * bitmap.pixelsHigh)
    guard let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.6]) else { throw ProbeError.message("JPEG fixture encoding failed") }
    for chunkSize in [1, 2, 7, 4096] {
        var parser = JPEGParser(), frames: [Data] = []
        var input = Data([1, 2, 0xff]); input.append(jpeg); input.append(jpeg)
        for index in stride(from: 0, to: input.count, by: chunkSize) {
            frames += parser.append(input.subdata(in: index..<min(index + chunkSize, input.count)))
        }
        try check(frames == [jpeg, jpeg], "JPEG boundaries, chunks=\(chunkSize)")
        try check(NSImage(data: frames[0]) != nil, "JPEG decodes")
    }
    let rect = imageRectangle(in: NSRect(x: 0, y: 0, width: 500, height: 500), size: NSSize(width: 100, height: 200))
    try check(rect == NSRect(x: 125, y: 0, width: 250, height: 500), "aspect-fit letterboxing")
    try check(normalized(NSPoint(x: 125, y: 0), in: rect) == .zero, "top-left origin")
    try check(normalized(NSPoint(x: 375, y: 500), in: rect) == NSPoint(x: 1, y: 1), "bottom-right coordinate")
    try check(normalized(NSPoint(x: -10, y: 800), in: rect) == NSPoint(x: 0, y: 1), "drag clamps outside image")
    try check(!rect.contains(NSPoint(x: 20, y: 20)), "letterbox cannot start touch")
    let pipe = Pipe(), writer = CommandWriter(pipe.fileHandleForWriting) { _ in }
    writer.send(["op": "touch", "phase": "down", "id": 1])
    for id in 2...100 { writer.send(["op": "touch", "phase": "move", "id": id], move: true) }
    writer.send(["op": "touch", "phase": "up", "id": 101]); writer.closeAfterPending()
    let commands = pipe.fileHandleForReading.readDataToEndOfFile().split(separator: 0x0a).compactMap {
        (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any]
    }
    try check(commands.first?["phase"] as? String == "down", "down retained")
    try check(commands.last?["phase"] as? String == "up", "up retained")
    let ids = commands.compactMap { $0["id"] as? Int }
    try check(ids == ids.sorted() && ids.contains(100), "move order and latest position retained")
    print("PASS: incremental JPEG parser, image decode, aspect-fit coordinates, ordered/coalesced control writer")
}

signal(SIGPIPE, SIG_IGN)
do {
    let options = try Options(Array(CommandLine.arguments.dropFirst()))
    if options.selfTest { try selfTest() }
    else {
        let app = NSApplication.shared
        let delegate = AppDelegate(options)
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1)
}
