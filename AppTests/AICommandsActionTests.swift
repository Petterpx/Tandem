import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct AICommandsActionTests {
    private let pixel = AIEnv.pixel

    private func env(_ elements: [UIElement] = []) -> AIEnv {
        var actions = FakeActions()
        let tree = AIEnv.tree(elements)
        actions.treeProvider = { tree }
        let e = AIEnv(actions: actions, sleep: { _ in })
        e.states[pixel.id] = .running(width: 1080, height: 2400)
        return e
    }

    private func asyncCode(_ body: () async throws -> Void) async -> DeviceError? {
        do { try await body() } catch { return error as? DeviceError }
        return nil
    }

    private func login(_ index: Int, y: CGFloat, desc: String = "", bounds: CGRect? = nil) -> UIElement {
        AIEnv.element(index, text: "登录", desc: desc, bounds: bounds ?? CGRect(x: 440, y: y - 50, width: 200, height: 100))
    }

    @Test func tapPointMapsToNormalized() async throws {
        let e = env()
        _ = try await e.commands.tap(pixel, .point(x: 288, y: 640))
        let p = NormalizedPoint(x: 0.5, y: 0.5)
        #expect(e.fake.sentActions == [.touch(.down, p, pointer: .ai), .touch(.up, p, pointer: .ai)])
    }

    @Test func tapByTextUsesFreshTree() async throws {
        let e = env([login(0, y: 1820)])
        _ = try await e.commands.tap(pixel, .text("登录"))
        guard case .touch(.down, let p, .ai) = e.fake.sentActions.first else { Issue.record("no down"); return }
        #expect(p.x == 0.5 && abs(p.y - 1820.0 / 2400) < 1e-9)
    }

    @Test func tapByTextAmbiguousListsCandidates() async {
        let e = env([login(0, y: 500), login(1, y: 1500)])
        let error = await asyncCode { _ = try await e.commands.tap(pixel, .text("登录")) }
        #expect(error?.code == .ELEMENT_AMBIGUOUS)
        let lines = error?.message.split(separator: "\n").filter { $0.hasPrefix("[") } ?? []
        #expect(lines.count == 2)
        #expect(e.commands.cachedTree(pixel.id) != nil)
        #expect(e.fake.sentActions.isEmpty)
    }

    @Test func hiddenNodeDoesNotCauseAmbiguity() async throws {
        let e = env([login(0, y: 1000), login(1, y: 0, bounds: .zero)])
        _ = try await e.commands.tap(pixel, .text("登录"))
        #expect(e.fake.sentActions.count == 2)
    }

    @Test func tapByTextNotFound() async {
        let e = env([login(0, y: 1000)])
        let error = await asyncCode { _ = try await e.commands.tap(pixel, .text("注册")) }
        #expect(error?.code == .ELEMENT_NOT_FOUND)
    }

    @Test func tapByIndexNeedsCache() async {
        let e = env()
        let error = await asyncCode { _ = try await e.commands.tap(pixel, .index(3)) }
        #expect(error?.code == .ELEMENT_NOT_FOUND && error?.suggestion?.contains("get_ui_tree") == true)
    }

    @Test func tapByIndexUsesCache() async throws {
        let e = env([login(4, y: 1200)])
        _ = try await e.commands.uiTree(pixel, all: true)
        _ = try await e.commands.tap(pixel, .index(4))
        #expect(e.fake.sentActions.count == 2)
        #expect(e.log.entries.first?.title == "tap 登录")
    }

    @Test func lockedActionIsRejectedAndLogged() async {
        let e = env()
        e.locks.setLocked(pixel.id, true)
        let error = await asyncCode { _ = try await e.commands.tap(pixel, .point(x: 1, y: 1)) }
        #expect(error?.code == .AI_LOCKED)
        #expect(e.log.entries.first?.source == .ai)
        #expect(e.log.entries.first?.failure == "设备已锁定，禁止 AI 操作")
        #expect(e.fake.sentActions.isEmpty)
    }

    @Test func swipeInterpolates() async throws {
        let e = env()
        _ = try await e.commands.swipe(pixel, from: (0, 0), to: (576, 1280), durationMs: 48)
        let sent = e.fake.sentActions
        #expect(sent.count == 5)
        #expect(sent.first == .touch(.down, .init(x: 0, y: 0), pointer: .ai))
        #expect(sent[1] == .touch(.move, .init(x: 1.0 / 3, y: 1.0 / 3), pointer: .ai))
        #expect(sent[3] == .touch(.move, .init(x: 1, y: 1), pointer: .ai))
        #expect(sent[4] == .touch(.up, .init(x: 1, y: 1), pointer: .ai))
    }

    @Test func longPressHoldsBetweenDownAndUp() async throws {
        let e = env()
        _ = try await e.commands.longPress(pixel, .point(x: 288, y: 640), durationMs: 800)
        #expect(e.fake.sentActions.count == 2)
        #expect(e.presence.indicators[pixel.id]?.kind == .longPress(.init(x: 0.5, y: 0.5), seconds: 0.8))
    }

    @Test func scrollDownMovesFingerUp() async throws {
        let e = env()
        _ = try await e.commands.scroll(pixel, .down, at: nil)
        guard case .touch(.down, let a, .ai) = e.fake.sentActions.first, case .touch(.up, let b, .ai) = e.fake.sentActions.last
        else { Issue.record("shape"); return }
        #expect(abs(a.y - 0.8) < 1e-9 && abs(b.y - 0.2) < 1e-9 && a.x == 0.5)
    }

    @Test func scrollRightMovesFingerLeft() async throws {
        let e = env()
        _ = try await e.commands.scroll(pixel, .right, at: nil)
        guard case .touch(.down, let a, .ai) = e.fake.sentActions.first, case .touch(.up, let b, .ai) = e.fake.sentActions.last
        else { Issue.record("shape"); return }
        #expect(abs(a.x - 0.8) < 1e-9 && abs(b.x - 0.2) < 1e-9)
    }

    @Test func scrollClampsAtEdge() async throws {
        let e = env()
        _ = try await e.commands.scroll(pixel, .down, at: (288, 1200))
        guard case .touch(.down, let a, .ai) = e.fake.sentActions.first else { Issue.record("no down"); return }
        #expect(a.y == 1.0)
    }

    @Test func asciiTextIsInjected() async throws {
        let e = env()
        _ = try await e.commands.typeText(pixel, "abc", submit: true)
        #expect(e.fake.sentActions == [.text("abc"), .key(.enter)])
    }

    @Test func nonASCIITextIsPasted() async throws {
        let e = env()
        _ = try await e.commands.typeText(pixel, "你好", submit: false)
        #expect(e.fake.setClipboardCalls.count == 1)
        #expect(e.fake.setClipboardCalls.first?.text == "你好" && e.fake.setClipboardCalls.first?.paste == true)
        #expect(e.fake.sentActions.isEmpty)
    }

    @Test func logTitleOmitsTypedText() async throws {
        let e = env()
        _ = try await e.commands.typeText(pixel, "secret", submit: false)
        #expect(e.log.entries.first?.title == "输入文字（6 字）")
        _ = try await e.commands.typeText(pixel, "secret", submit: true)
        #expect(e.log.entries.first?.title == "输入文字（6 字）并回车")
    }

    @Test func setClipboardWritesWithoutLoggingContent() async throws {
        let e = env()
        _ = try await e.commands.setClipboard(pixel, text: "pw", paste: true)
        #expect(e.fake.setClipboardCalls.first?.text == "pw")
        #expect(e.presence.indicators[pixel.id]?.label == "写入并粘贴")
    }

    @Test func pressKeySendsKey() async throws {
        let e = env()
        _ = try await e.commands.pressKey(pixel, .back)
        #expect(e.fake.sentActions == [.key(.back)])
        #expect(e.presence.indicators[pixel.id]?.label == "press_key back")
    }

    @Test func keyNames() {
        #expect(AICommands.deviceKey(named: "volume_up") == .volumeUp)
        #expect(AICommands.deviceKey(named: "x") == nil)
    }

    @Test func indicatorShownAfterTap() async throws {
        let e = env()
        _ = try await e.commands.tap(pixel, .point(x: 288, y: 640))
        #expect(e.presence.indicators[pixel.id]?.label == "tap (288,640)")
    }

    @Test func concurrentTapsOnOneDeviceDoNotInterleave() async throws {
        let e = env()
        // 每次 send 都会挂起一下，未串行化时两次点按的 down / up 会交错
        e.fake.sendDelay = .milliseconds(20)
        async let first = e.commands.tap(pixel, .point(x: 0, y: 0))
        async let second = e.commands.tap(pixel, .point(x: 576, y: 1280))
        _ = try await (first, second)
        let sent = e.fake.sentActions.compactMap { action -> (TouchPhase, NormalizedPoint)? in
            guard case .touch(let phase, let p, .ai) = action else { return nil }
            return (phase, p)
        }
        #expect(sent.map(\.0) == [.down, .up, .down, .up])
        #expect(sent.count == 4 && sent[0].1 == sent[1].1 && sent[2].1 == sent[3].1)
    }

    @Test func indicatorIsShownBeforeTouchDown() async throws {
        let probe = PresenceProbe()
        var actions = FakeActions()
        actions.treeProvider = { AIEnv.tree([]) }
        // 长按 / 滑动在 down 之后才 sleep：sleep 时提示必须已经出现
        let e = AIEnv(actions: actions, sleep: { _ in await probe.record() })
        e.states[pixel.id] = .running(width: 1080, height: 2400)
        probe.presence = e.presence
        _ = try await e.commands.longPress(pixel, .point(x: 288, y: 640), durationMs: 800)
        #expect(probe.seen.first == .longPress(.init(x: 0.5, y: 0.5), seconds: 0.8))
        _ = try await e.commands.swipe(pixel, from: (0, 0), to: (576, 1280), durationMs: 48)
        #expect(probe.seen.count == 4)
        #expect(probe.seen.dropFirst().allSatisfy { $0 == .swipe(.init(x: 0, y: 0), .init(x: 1, y: 1)) })
    }

    @Test func disconnectWhileWaitingFailsFast() async {
        let e = AIEnv(hasSession: false, sleep: { _ in })
        e.onAcquire = { _ in e.devices = [] }
        let start = ContinuousClock.now
        let error = await asyncCode { _ = try await e.commands.tap(pixel, .point(x: 1, y: 1)) }
        #expect(error?.code == .DEVICE_NOT_FOUND && error?.message == "设备已断开")
        #expect(ContinuousClock.now - start < .milliseconds(250))
    }
}

/// 记下 AICommands 每次 sleep 时设备上显示的提示。
@MainActor
private final class PresenceProbe {
    var presence: AIPresence?
    private(set) var seen: [AIIndicator.Kind?] = []

    func record() { seen.append(presence?.indicators[AIEnv.pixel.id]?.kind) }
}
