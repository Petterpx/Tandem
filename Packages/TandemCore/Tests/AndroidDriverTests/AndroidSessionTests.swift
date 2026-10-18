import CoreVideo
import Foundation
import Testing
import DeviceCore
@testable import AndroidDriver

// MARK: - 测试替身

final class FakeLauncher: ScrcpyLauncher, @unchecked Sendable {
    final class Server: @unchecked Sendable {
        let video = InMemoryByteStream()
        let control = InMemoryByteStream()
        private let lock = NSLock()
        private var lines: [String]
        private var _pulls = 0
        /// logs 流被拉取的次数（第 n 次拉取说明前 n-1 行已处理完）。
        var logPulls: Int { lock.withLock { _pulls } }

        init(lines: [String]) { self.lines = lines }

        func nextLine() -> String? {
            lock.withLock {
                _pulls += 1
                return lines.isEmpty ? nil : lines.removeFirst()
            }
        }
    }

    private let lock = NSLock()
    private var _servers: [Server] = []
    private var _options: [ScrcpyLaunchOptions] = []
    private var _serials: [String] = []
    private var _stops = 0
    var failure: DeviceError?
    var logLines: [String] = []
    /// 模拟卡住的启动（例如握手无响应）：直到被取消才返回。
    var hangUntilCancelled = false
    /// 模拟不理会取消的启动：挂起直到被取消，然后仍然成功返回一个 LaunchedServer。
    var completeAfterCancel = false
    private var _stopHeld = false
    /// 为 true 时 LaunchedServer.stop 会卡住，直到 releaseStop()（让断开清理保持进行中）。
    var stopHeld: Bool {
        get { lock.withLock { _stopHeld } }
        set { lock.withLock { _stopHeld = newValue } }
    }
    func releaseStop() { stopHeld = false }
    private var _stopEntered = 0
    var stopEnteredCount: Int { lock.withLock { _stopEntered } }

    var servers: [Server] { lock.withLock { _servers } }
    var options: [ScrcpyLaunchOptions] { lock.withLock { _options } }
    var serials: [String] { lock.withLock { _serials } }
    var stopCount: Int { lock.withLock { _stops } }
    var server: Server { servers.last! }

    func launch(serial: String, options: ScrcpyLaunchOptions) async throws -> LaunchedServer {
        let (server, failure): (Server, DeviceError?) = lock.withLock {
            _options.append(options)
            _serials.append(serial)
            let s = Server(lines: logLines)
            if self.failure == nil { _servers.append(s) }
            return (s, self.failure)
        }
        if let failure { throw failure }
        if hangUntilCancelled { try await Task.sleep(for: .seconds(3600)) }
        if completeAfterCancel { try? await Task.sleep(for: .seconds(3600)) }
        let logs = AsyncStream<String>(unfolding: { server.nextLine() })
        return LaunchedServer(
            connection: ScrcpyConnection(deviceName: "Pixel 8", video: server.video, control: server.control),
            logs: logs,
            stop: { [self] in
                lock.withLock { _stopEntered += 1 }
                while stopHeld { try? await Task.sleep(for: .milliseconds(1)) }
                lock.withLock { _stops += 1 }
                server.video.close()
                server.control.close()
            })
    }
}

final class FakeDecoder: VideoDecoding, @unchecked Sendable {
    enum Call: Equatable { case config(Data), frame(Data, UInt64), reset }
    private let lock = NSLock()
    private var _calls: [Call] = []
    let onFrame: @Sendable (VideoFrame) -> Void
    var calls: [Call] { lock.withLock { _calls } }

    init(onFrame: @escaping @Sendable (VideoFrame) -> Void) { self.onFrame = onFrame }
    func decode(config annexB: Data) { lock.withLock { _calls.append(.config(annexB)) } }
    func decode(frame annexB: Data, pts: UInt64) { lock.withLock { _calls.append(.frame(annexB, pts)) } }
    func reset() { lock.withLock { _calls.append(.reset) } }
}

final class DecoderFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var _made: [FakeDecoder] = []
    var made: [FakeDecoder] { lock.withLock { _made } }
    var last: FakeDecoder { made.last! }

    func make(_ onFrame: @escaping @Sendable (VideoFrame) -> Void) -> any VideoDecoding {
        let d = FakeDecoder(onFrame: onFrame)
        lock.withLock { _made.append(d) }
        return d
    }
}

final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [SessionEvent] = []
    private var task: Task<Void, Never>?
    var events: [SessionEvent] { lock.withLock { _events } }

    init(_ stream: AsyncStream<SessionEvent>) {
        task = Task { [weak self] in
            for await e in stream { self?.lock.withLock { self?._events.append(e) } }
        }
    }

    deinit { task?.cancel() }

    /// 有上限的轮询，直到 predicate 成立；返回此时的事件。
    @discardableResult
    func wait(timeout: Duration = .seconds(2), until predicate: ([SessionEvent]) -> Bool) async -> [SessionEvent] {
        await eventually(timeout: timeout) { predicate(self.events) }
        return events
    }

    @discardableResult
    func waitFor(_ event: SessionEvent, count: Int = 1) async -> [SessionEvent] {
        await wait { $0.filter { $0 == event }.count >= count }
    }
}

@discardableResult
func eventually(timeout: Duration = .seconds(2), isolation: isolated (any Actor)? = #isolation,
                _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return true
}

// MARK: - 报文构造

private func be32(_ v: UInt32) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
private func be64(_ v: UInt64) -> [UInt8] { withUnsafeBytes(of: v.bigEndian, Array.init) }
private let h264Codec = be32(0x68323634)

private func sessionPacket(_ w: UInt32, _ h: UInt32) -> [UInt8] { [0x80, 0, 0, 0] + be32(w) + be32(h) }

private func mediaPacket(config: Bool = false, pts: UInt64 = 0, _ payload: [UInt8]) -> [UInt8] {
    var head = be64(pts)
    if config { head[0] |= 0x40 }
    return head + be32(UInt32(payload.count)) + payload
}

private let device = DeviceInfo(serial: "SER", platform: .android, name: "Pixel 8", state: .connected, connection: .usb)

private struct Harness {
    let launcher = FakeLauncher()
    let decoders = DecoderFactory()
    let session: AndroidSession
    let recorder: EventRecorder

    init(clipboardTimeout: Duration = .seconds(2), logLines: [String] = []) {
        launcher.logLines = logLines
        let decoders = self.decoders
        session = AndroidSession(device: device, launcher: launcher, makeDecoder: { decoders.make($0) },
                                 clipboardTimeout: clipboardTimeout)
        recorder = EventRecorder(session.events)
    }

    /// start 并喂 codec + session 包，等到 running。
    func startRunning(width: UInt32 = 1080, height: UInt32 = 2400) async {
        await session.start()
        launcher.server.video.feed(h264Codec + sessionPacket(width, height))
        await recorder.waitFor(.state(.running(width: Int(width), height: Int(height))))
    }
}

// MARK: - 测试

struct AndroidSessionTests {
    @Test func runningAfterSessionPacket() async {
        let h = Harness()
        await h.session.start()
        h.launcher.server.video.feed(h264Codec + sessionPacket(1080, 2400))
        let events = await h.recorder.wait { $0.count >= 2 }
        #expect(events == [.state(.connecting), .state(.running(width: 1080, height: 2400))])
        #expect(h.launcher.serials == ["SER"])
        let options = h.launcher.options[0]
        #expect(options.scid <= 0x7fff_ffff)
        #expect(options == ScrcpyLaunchOptions.for(.usb, scid: options.scid))
        #expect(h.decoders.last.calls == [.reset])
    }

    @Test func rotationEmitsNewSizeAndResetsDecoder() async {
        let h = Harness()
        await h.startRunning(width: 1080, height: 2400)
        let video = h.launcher.server.video
        video.feed(mediaPacket(config: true, [1, 2, 3]))
        video.feed(sessionPacket(2400, 1080))
        video.feed(mediaPacket(config: true, [4, 5]))
        let events = await h.recorder.waitFor(.state(.running(width: 2400, height: 1080)))
        #expect(events.last == .state(.running(width: 2400, height: 1080)))
        let expected: [FakeDecoder.Call] = [.reset, .config(Data([1, 2, 3])), .reset, .config(Data([4, 5]))]
        await eventually { h.decoders.last.calls.count >= expected.count }
        #expect(h.decoders.last.calls == expected)
    }

    @Test func mediaFramesGoToDecoderAndFramesReachObserver() async throws {
        let h = Harness()
        let received = Recorder<VideoFrame>()
        _ = h.session.addFrameObserver { received.append($0) }
        await h.startRunning()
        h.launcher.server.video.feed(mediaPacket(pts: 1234, [9, 9, 9]))
        await eventually { h.decoders.last.calls.count >= 2 }
        #expect(h.decoders.last.calls == [.reset, .frame(Data([9, 9, 9]), 1234)])

        #expect(h.session.latestFrame() == nil)
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
        let pixelBuffer = try #require(buffer)
        h.decoders.last.onFrame(VideoFrame(pixelBuffer: pixelBuffer))
        #expect(h.session.latestFrame()?.pixelBuffer === pixelBuffer)
        #expect(received.values.count == 1 && received.values[0].pixelBuffer === pixelBuffer)
    }

    @Test func everyObserverReceivesFrames() async throws {
        let h = Harness()
        let a = Recorder<VideoFrame>(), b = Recorder<VideoFrame>()
        let ta = h.session.addFrameObserver { a.append($0) }
        _ = h.session.addFrameObserver { b.append($0) }
        await h.startRunning()
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
        let frame = VideoFrame(pixelBuffer: try #require(buffer))
        h.decoders.last.onFrame(frame)
        #expect(a.values.count == 1 && b.values.count == 1)
        h.session.removeFrameObserver(ta)
        h.decoders.last.onFrame(frame)
        #expect(a.values.count == 1 && b.values.count == 2)
    }

    @Test func tapMapsNormalizedToVideoPixels() async {
        let h = Harness()
        await h.startRunning(width: 1080, height: 2400)
        await h.session.send(.touch(.down, .init(x: 0.5, y: 0.25)))
        let expected = ControlMessage.injectTouch(action: .down, pointerId: PointerId.genericFinger, x: 540, y: 600,
                                                  screenWidth: 1080, screenHeight: 2400, pressure: 1.0, actionButton: 0, buttons: 0)
        #expect(h.launcher.server.control.written == expected.encoded())
    }

    @Test func touchClampsAndReleasesWithZeroPressure() async {
        let h = Harness()
        await h.startRunning(width: 1080, height: 2400)
        await h.session.send(.touch(.move, .init(x: 1.0, y: -0.5)))
        await h.session.send(.touch(.up, .init(x: 2, y: 1)))
        let expected = ControlMessage.injectTouch(action: .move, pointerId: PointerId.genericFinger, x: 1079, y: 0,
                                                  screenWidth: 1080, screenHeight: 2400, pressure: 1.0, actionButton: 0, buttons: 0).encoded()
            + ControlMessage.injectTouch(action: .up, pointerId: PointerId.genericFinger, x: 1079, y: 2399,
                                         screenWidth: 1080, screenHeight: 2400, pressure: 0, actionButton: 0, buttons: 0).encoded()
        #expect(h.launcher.server.control.written == expected)
    }

    @Test func scrollIsClampedToSixteen() async {
        let h = Harness()
        await h.startRunning(width: 1080, height: 2400)
        await h.session.send(.scroll(.init(x: 0.5, y: 0.5), dx: -40, dy: 3))
        let expected = ControlMessage.injectScroll(x: 540, y: 1200, screenWidth: 1080, screenHeight: 2400, hscroll: -16, vscroll: 3, buttons: 0)
        #expect(h.launcher.server.control.written == expected.encoded())
    }

    @Test func longAsciiIsChunked() async {
        let h = Harness()
        await h.startRunning()
        await h.session.send(.text(String(repeating: "a", count: 650)))
        let expected = [300, 300, 50].map { ControlMessage.injectText(String(repeating: "a", count: $0)).encoded() }.reduce(Data(), +)
        #expect(h.launcher.server.control.written == expected)
    }

    @Test func nonAsciiUsesClipboardPaste() async {
        let h = Harness(clipboardTimeout: .seconds(10))
        await h.startRunning()
        let started = ContinuousClock.now
        let send = Task { await h.session.send(.text("你好 test")) }
        let expected = ControlMessage.setClipboard(sequence: 1, text: "你好 test", paste: true).encoded()
        let written = await h.launcher.server.control.waitForWritten(atLeast: expected.count)
        #expect(written == expected)
        h.launcher.server.control.feed([0x01] + be64(1))
        await send.value
        #expect(ContinuousClock.now - started < .seconds(5))  // 由 ack 放行，而不是等到超时
    }

    @Test func setClipboardAwaitsMatchingAck() async throws {
        let h = Harness(clipboardTimeout: .seconds(10))
        await h.startRunning()
        let first = Task { try await h.session.setClipboard("one", paste: false) }
        let firstBytes = ControlMessage.setClipboard(sequence: 1, text: "one", paste: false).encoded()
        _ = await h.launcher.server.control.waitForWritten(atLeast: firstBytes.count)
        let second = Task { try await h.session.setClipboard("two", paste: false) }
        let bothBytes = firstBytes + ControlMessage.setClipboard(sequence: 2, text: "two", paste: false).encoded()
        #expect(await h.launcher.server.control.waitForWritten(atLeast: bothBytes.count) == bothBytes)
        h.launcher.server.control.feed([0x01] + be64(2))
        try await second.value
        h.launcher.server.control.feed([0x01] + be64(1))
        try await first.value
    }

    @Test func setClipboardTimesOut() async {
        let h = Harness(clipboardTimeout: .milliseconds(50))
        await h.startRunning()
        let error = await #expect(throws: DeviceError.self) { try await h.session.setClipboard("x", paste: false) }
        #expect(error == .timeout("写入剪切板"))
    }

    @Test func backUsesBackOrScreenOn() async {
        let h = Harness()
        await h.startRunning()
        await h.session.send(.key(.back))
        #expect([UInt8](h.launcher.server.control.written) == [0x04, 0x00, 0x04, 0x01])
    }

    @Test func keysUseKeycodeTable() async {
        let table: [(DeviceKey, UInt32)] = [(.home, 3), (.recents, 187), (.volumeUp, 24), (.volumeDown, 25), (.power, 26), (.enter, 66),
                                            (.delete, 67), (.forwardDelete, 112), (.tab, 61), (.up, 19), (.down, 20), (.left, 21), (.right, 22)]
        let h = Harness()
        await h.startRunning()
        var expected = Data()
        for (key, code) in table {
            await h.session.send(.key(key))
            expected += ControlMessage.injectKeycode(action: .down, keycode: code, repeat: 0, metaState: 0).encoded()
            expected += ControlMessage.injectKeycode(action: .up, keycode: code, repeat: 0, metaState: 0).encoded()
        }
        #expect(h.launcher.server.control.written == expected)
    }

    @Test func inputWhenNotRunningIsDropped() async {
        let h = Harness()
        await h.session.send(.key(.home))  // start 之前
        await h.session.start()
        await h.session.send(.key(.home))  // connecting，还没有 session 包
        h.launcher.server.video.feed(h264Codec + sessionPacket(1080, 2400))
        await h.recorder.waitFor(.state(.running(width: 1080, height: 2400)))
        #expect(h.launcher.server.control.written.isEmpty)
    }

    @Test func getClipboardReturnsDeviceText() async throws {
        let h = Harness()
        await h.startRunning()
        let read = Task { try await h.session.getClipboard() }
        #expect([UInt8](await h.launcher.server.control.waitForWritten(atLeast: 2)) == [0x08, 0x00])
        let text = Array("复制的内容".utf8)
        h.launcher.server.control.feed([0x00] + be32(UInt32(text.count)) + text)
        #expect(try await read.value == "复制的内容")
    }

    @Test func getClipboardTimesOut() async {
        let h = Harness(clipboardTimeout: .milliseconds(50))
        await h.startRunning()
        let error = await #expect(throws: DeviceError.self) { _ = try await h.session.getClipboard() }
        #expect(error?.code == .TIMEOUT)
        #expect(error == .timeout("读取剪切板"))
    }

    @Test func videoEOFEmitsDisconnectedAndCallsStop() async {
        let h = Harness()
        await h.startRunning()
        h.launcher.server.video.finish()
        let events = await h.recorder.waitFor(.state(.disconnected))
        #expect(events == [.state(.connecting), .state(.running(width: 1080, height: 2400)), .state(.disconnected)])
        #expect(h.launcher.stopCount == 1)

        await h.session.start()
        await h.recorder.waitFor(.state(.connecting), count: 2)
        #expect(h.launcher.options.count == 2)
        #expect(h.launcher.servers.count == 2)
    }

    @Test func stopAfterDisconnectStopsServerOnceInOrder() async {
        let h = Harness()
        await h.startRunning()
        h.launcher.server.video.finish()
        await h.session.stop()
        let events = await h.recorder.waitFor(.state(.idle))
        // stop 可能先于或晚于断开处理被调度，但服务端只停一次，且不会出现 idle 在 disconnected 之前。
        #expect(h.launcher.stopCount == 1)
        #expect(events.last == .state(.idle))
        #expect(events.filter { $0 == .state(.idle) }.count == 1)
        #expect(events.filter { $0 == .state(.disconnected) }.count <= 1)
    }

    @Test func stopWhileRunningEmitsIdleAndCleansUp() async {
        let h = Harness()
        await h.startRunning()
        await h.session.stop()
        let events = await h.recorder.waitFor(.state(.idle))
        #expect(events == [.state(.connecting), .state(.running(width: 1080, height: 2400)), .state(.idle)])
        #expect(h.launcher.stopCount == 1)
        await h.session.send(.key(.home))
        #expect(h.launcher.server.control.written.isEmpty)
    }

    @Test func pendingClipboardFailsOnStop() async {
        let h = Harness(clipboardTimeout: .seconds(10))
        await h.startRunning()
        let read = Task { try await h.session.getClipboard() }
        _ = await h.launcher.server.control.waitForWritten(atLeast: 2)
        await h.session.stop()
        let error = await #expect(throws: DeviceError.self) { _ = try await read.value }
        #expect(error?.code == .CONNECTION_FAILED)
    }

    @Test func unsupportedCodecFails() async {
        let h = Harness()
        await h.session.start()
        h.launcher.server.video.feed(be32(0x68323635))  // h265
        let events = await h.recorder.wait { $0.count >= 2 }
        #expect(events == [.state(.connecting), .state(.failed(.connectionFailed("视频编码不受支持")))])
        #expect(h.launcher.stopCount == 1)
    }

    @Test func zeroSizedSessionPacketFails() async {
        let h = Harness()
        await h.session.start()
        h.launcher.server.video.feed(h264Codec + sessionPacket(0, 2400))
        let events = await h.recorder.wait { $0.count >= 2 }
        #expect(events.count == 2)
        guard case .state(.failed(let error)) = events.last else { Issue.record("expected failed, got \(events)"); return }
        #expect(error.code == .CONNECTION_FAILED)
        #expect(h.launcher.stopCount == 1)
    }

    @Test func stopCancelsHungLaunch() async {
        let h = Harness()
        h.launcher.hangUntilCancelled = true
        let returned = Recorder<Bool>()
        let start = Task { await h.session.start(); returned.append(true) }
        await h.recorder.waitFor(.state(.connecting))
        await h.session.stop()
        #expect(await eventually { !returned.values.isEmpty }, "stop 之后 start 仍卡在 launch 里")
        start.cancel()
        #expect(h.recorder.events == [.state(.connecting), .state(.idle)])
    }

    @Test func stopWaitsForCleanupOfLaunchThatIgnoresCancellation() async {
        let h = Harness()
        h.launcher.completeAfterCancel = true
        let start = Task { await h.session.start() }
        await h.recorder.waitFor(.state(.connecting))
        await h.session.stop()
        // stop 返回时，迟到的 LaunchedServer 必须已经被清理（且只清理一次）。
        #expect(h.launcher.stopCount == 1)
        #expect(h.recorder.events == [.state(.connecting), .state(.idle)])
        await start.value
        #expect(h.launcher.stopCount == 1)
    }

    @Test func latestFrameIsClearedWhenANewRunStarts() async throws {
        let h = Harness()
        await h.startRunning()
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, nil, &buffer)
        h.decoders.last.onFrame(VideoFrame(pixelBuffer: try #require(buffer)))
        h.launcher.server.video.finish()
        await h.recorder.waitFor(.state(.disconnected))
        // 断开后仍保留最后一帧（窗口在「已断开」遮罩下显示）。
        #expect(h.session.latestFrame() != nil)
        await h.session.start()
        await h.recorder.waitFor(.state(.connecting), count: 2)
        // 新的 run 不能把上一个 run 的旧画面当作最新帧。
        #expect(h.session.latestFrame() == nil)
    }

    @Test func activeSerialTracksTheRunningTransport() async {
        let h = Harness()
        #expect(h.session.activeSerial == nil)
        await h.startRunning()
        #expect(h.session.activeSerial == "SER")
        h.launcher.server.video.finish()
        await h.recorder.waitFor(.state(.disconnected))
        #expect(h.session.activeSerial == nil)
    }

    /// 首选传输变了（例如 Wi-Fi 投屏时插上 USB）：进行中的 run 不受影响，下一次 start 用新的 serial 与参数。
    @Test func updateDeviceAppliesToTheNextRun() async {
        let h = Harness()
        var wifi = device
        wifi.serial = "192.168.1.23:5555"
        wifi.connection = .wifi
        h.session.updateDevice(wifi)
        await h.startRunning()
        #expect(h.launcher.serials == ["192.168.1.23:5555"])
        #expect(h.launcher.options[0] == ScrcpyLaunchOptions.for(.wifi, scid: h.launcher.options[0].scid))
        #expect(h.session.activeSerial == "192.168.1.23:5555")

        h.session.updateDevice(device)
        #expect(h.session.activeSerial == "192.168.1.23:5555")  // 进行中的 run 不变
        await h.session.stop()
        await h.session.start()
        #expect(h.launcher.serials == ["192.168.1.23:5555", "SER"])
        #expect(h.launcher.options[1] == ScrcpyLaunchOptions.for(.usb, scid: h.launcher.options[1].scid))
        #expect(h.session.activeSerial == "SER")
    }

    /// 断开清理进行中时依次调用 stop()、start()：按调用顺序生效——先 idle，再开始新的连接。
    @MainActor @Test func stopThenStartDuringDisconnectTeardownAreOrdered() async {
        let h = Harness()
        await h.startRunning()
        h.launcher.stopHeld = true
        h.launcher.server.video.finish()
        await eventually { h.launcher.stopEnteredCount == 1 }  // 断开清理已开始并卡在 stop 里
        let stop = Task { await h.session.stop() }
        let start = Task { await h.session.start() }
        for _ in 0..<100 { await Task.yield() }
        h.launcher.releaseStop()
        await stop.value
        await start.value
        let events = await h.recorder.waitFor(.state(.connecting), count: 2)
        #expect(events == [.state(.connecting), .state(.running(width: 1080, height: 2400)), .state(.disconnected),
                           .state(.idle), .state(.connecting)])
        #expect(h.launcher.options.count == 2)
        #expect(h.launcher.stopCount == 1)
        // 新的 run 是活的：喂 session 包能进入 running。
        h.launcher.server.video.feed(h264Codec + sessionPacket(1080, 2400))
        await h.recorder.waitFor(.state(.running(width: 1080, height: 2400)), count: 2)
        #expect(h.recorder.events.last == .state(.running(width: 1080, height: 2400)))
    }

    /// 断开清理进行中时依次调用 start()、stop()：stop 胜出，不会留下活着的启动。
    @MainActor @Test func startThenStopDuringDisconnectTeardownLeavesIdle() async {
        let h = Harness()
        await h.startRunning()
        h.launcher.stopHeld = true
        h.launcher.server.video.finish()
        await eventually { h.launcher.stopEnteredCount == 1 }
        let start = Task { await h.session.start() }
        let stop = Task { await h.session.stop() }
        for _ in 0..<100 { await Task.yield() }
        h.launcher.releaseStop()
        await start.value
        await stop.value
        let events = h.recorder.events
        #expect(events.last == .state(.idle))
        #expect(events.filter { $0 == .state(.disconnected) }.count == 1)
        // 若发起了第二次启动，它必须已被清理掉。
        #expect(h.launcher.stopCount == h.launcher.servers.count)
    }

    /// 并发的 send（UI 连续触摸）必须按进入会话的顺序到达控制 socket，且不并发写。
    @MainActor @Test func concurrentSendsKeepOrder() async {
        let h = Harness()
        await h.startRunning(width: 1000, height: 1000)
        h.launcher.server.control.writeDelay = { .microseconds(Int.random(in: 0...3000)) }
        var actions: [InputAction] = [.touch(.down, .init(x: 0, y: 0))]
        actions += (1...18).map { .touch(.move, .init(x: Double($0) / 100, y: 0)) }
        actions.append(.touch(.up, .init(x: 0.19, y: 0)))
        let tasks = actions.map { action in Task { await h.session.send(action) } }
        for task in tasks { await task.value }
        let expected = actions.map { action -> Data in
            guard case let .messages(m) = InputMapper.map(action, width: 1000, height: 1000) else { return Data() }
            return m.reduce(into: Data()) { $0 += $1.encoded() }
        }.reduce(Data(), +)
        #expect(h.launcher.server.control.written == expected)
        #expect(h.launcher.server.control.maxInFlightWrites == 1)
    }

    @Test func launchFailureEmitsFailed() async {
        let h = Harness()
        h.launcher.failure = .connectionFailed("adb push 失败")
        await h.session.start()
        let events = await h.recorder.wait { $0.count >= 2 }
        #expect(events == [.state(.connecting), .state(.failed(.connectionFailed("adb push 失败")))])
        #expect(h.launcher.stopCount == 0)
    }

    @Test func injectPermissionEventFiresOnce() async {
        let line = "java.lang.SecurityException: Injecting input events requires the caller to have the INJECT_EVENTS permission."
        let h = Harness(logLines: [line, line])
        await h.startRunning()
        // 第 3 次拉取 logs 说明两行都已处理完。
        await eventually { h.launcher.server.logPulls >= 3 }
        await h.session.stop()
        let events = await h.recorder.waitFor(.state(.idle))
        #expect(events.filter { $0 == .injectPermissionDenied }.count == 1)
    }
}
