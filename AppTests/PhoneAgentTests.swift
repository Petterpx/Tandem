import ControlProtocol
import DeviceCore
import Foundation
import Testing
@testable import Tandem

/// Deliberately continues inference after cancellation: the runner must check
/// cancellation itself before forwarding the resulting device input.
private actor TestPhonePlanner: PhoneAgentPlanning {
    private var decisions: [PhoneAgentDecision]
    private var inputs: [PhoneAgentInput] = []
    private var gate: CheckedContinuation<Void, Never>?
    private var holdFirst: Bool

    init(_ decisions: [PhoneAgentDecision], holdFirst: Bool = false) {
        self.decisions = decisions
        self.holdFirst = holdFirst
    }

    func decide(_ input: PhoneAgentInput, configuration: PhoneAgentConfiguration) async throws -> PhoneAgentDecision {
        inputs.append(input)
        if holdFirst {
            holdFirst = false
            await withCheckedContinuation { gate = $0 }
        }
        guard !decisions.isEmpty else { throw PlannerFailure.exhausted }
        return decisions.removeFirst()
    }

    func resume() { gate?.resume(); gate = nil }
    func receivedInputs() -> [PhoneAgentInput] { inputs }
    private enum PlannerFailure: Error { case exhausted }
}

@MainActor
private final class PhoneAgentHarness {
    let env = AIEnv()
    var devices = [AIEnv.pixel.id: AIEnv.pixel]
    var locked = false
    var calls: [(name: String, arguments: [String: JSONValue])] = []
    var released: [String] = []
    var failAction = false
    var throwAction = false
    var screenshotResult: ToolResult?
    var catalogResult: ToolResult = .text("name: WeChat\tbundleID: com.tencent.xin")
    private var screenshots = 0
    lazy var registry = ToolRegistry(commands: env.commands)

    func agent(_ planner: TestPhonePlanner, maxSteps: Int = 24) -> PhoneAgent {
        PhoneAgent(
            planner: planner,
            configuration: {
                PhoneAgentConfiguration(provider: .codex, model: "test", baseURL: "", apiKey: "", codexPath: "codex")
            },
            device: { self.devices[$0] }, isLocked: { _ in self.locked },
            descriptors: { self.registry.descriptors(for: [$0]) },
            call: { name, arguments in
                self.calls.append((name, arguments))
                if name == "list_apps" { return self.catalogResult }
                if name == "screenshot" {
                    self.screenshots += 1
                    if let result = self.screenshotResult { return result }
                    let width = 585 + self.screenshots
                    return ToolResult(content: [
                        .image(data: AIEnv.png(width: width, height: 1280), mimeType: "image/png"),
                        .text("\(width)x1280，来源：测试截图"),
                    ])
                }
                if self.throwAction { throw DeviceError.connectionFailed("传输中断") }
                return ToolResult(content: [.text(self.failAction ? "执行结果未知" : "OK")], isError: self.failAction)
            },
            release: { self.released.append($0) }, maxSteps: maxSteps, settle: .zero)
    }
}

@MainActor
@Suite struct PhoneAgentTests {
    private static func act(_ tool: String = "tap", arguments: String = "{\"x\":20,\"y\":30}") -> PhoneAgentDecision {
        PhoneAgentDecision(kind: .act, summary: "点按目标", tool: tool, argumentsJSON: arguments)
    }
    private static let done = PhoneAgentDecision(kind: .done, summary: "已确认完成", tool: "", argumentsJSON: "{}")

    private func waitForInference(_ planner: TestPhonePlanner) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < deadline {
            if !(await planner.receivedInputs()).isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return false
    }

    @Test func observesAfterEveryActionAndBindsAllCallsToSelectedDevice() async throws {
        let h = PhoneAgentHarness()
        var selected = AIEnv.pixel
        selected.serial = "second-transport"
        selected.hardwareSerial = "selected-phone"
        selected.name = "Selected Pixel"
        h.devices[selected.id] = selected
        let planner = TestPhonePlanner([Self.act(), Self.done])
        let agent = h.agent(planner)
        agent.start(goal: "  打开目标页面  ", deviceID: selected.id)
        await agent.waitUntilFinished()

        #expect(h.calls.map(\.name) == ["screenshot", "tap", "screenshot"])
        #expect(h.calls.allSatisfy { $0.arguments["device"] == .string(selected.id) })
        #expect(h.released == [selected.id])
        #expect(agent.activeDeviceID == nil)
        #expect(agent.runs[AIEnv.pixel.id] == nil)
        #expect(agent.runs[selected.id]?.status == .completed)
        #expect(agent.runs[selected.id]?.goal == "打开目标页面")
        #expect(agent.runs[selected.id]?.steps.count == 1)
        #expect(agent.runs[selected.id]?.steps.first?.result == "OK")
        let timedStep = try #require(agent.runs[selected.id]?.steps.first)
        #expect(try #require(timedStep.planningSeconds) >= 0)
        #expect(try #require(timedStep.executionSeconds) >= 0)
        let inputs = await planner.receivedInputs()
        #expect(inputs.count == 2)
        let first = try #require(inputs.first)
        let last = try #require(inputs.last)
        #expect(first.deviceName == selected.name && first.platform == "android")
        #expect(first.step == 1 && first.history.isEmpty)
        #expect(last.step == 2 && last.history.count == 1)
        #expect(first.image != last.image)
        #expect(last.history.first?.tool == "tap")
        #expect(last.history.first?.arguments["device"] == nil)
        #expect(last.history.first?.arguments["x"] == 20)
        #expect(first.tools.allSatisfy { $0.inputSchema["properties"]?["device"] == nil })
        #expect(!first.tools.contains { ["shell", "install_app", "list_devices", "screenshot"].contains($0.name) })
    }

    @Test(arguments: [
        ("tap", "{\"device\":\"other-phone\",\"x\":20,\"y\":30}"),
        ("shell", "{\"command\":\"input tap 20 30\"}"),
        ("tap", "{\"x\":20,\"y\":30,\"unexpected\":true}"),
    ])
    func rejectsUnscopedModelActions(tool: String, arguments: String) async {
        let h = PhoneAgentHarness()
        let planner = TestPhonePlanner([Self.act(tool, arguments: arguments)])
        let agent = h.agent(planner)
        agent.start(goal: "执行操作", deviceID: AIEnv.pixel.id)
        await agent.waitUntilFinished()
        #expect(agent.runs[AIEnv.pixel.id]?.status == .failed)
        #expect(agent.runs[AIEnv.pixel.id]?.steps.isEmpty == true)
        #expect(h.calls.map(\.name) == ["screenshot"])
        #expect(h.released == [AIEnv.pixel.id])
    }

    @Test(arguments: [
        "{\"x\":-1,\"y\":30}", "{\"x\":586,\"y\":30}",
        "{\"x\":20,\"y\":1280}", "{\"x\":\"20\",\"y\":30}",
    ])
    func rejectsCoordinatesOutsideObservedPixels(arguments: String) async {
        let h = PhoneAgentHarness()
        let planner = TestPhonePlanner([Self.act(arguments: arguments)])
        let agent = h.agent(planner)
        agent.start(goal: "点按", deviceID: AIEnv.pixel.id)
        await agent.waitUntilFinished()
        #expect(agent.runs[AIEnv.pixel.id]?.status == .failed)
        #expect(h.calls.map(\.name) == ["screenshot"])
        #expect(h.released == [AIEnv.pixel.id])
    }

    @Test(arguments: [false, true])
    func invalidScreenshotStopsBeforeInference(missingImage: Bool) async {
        let h = PhoneAgentHarness()
        h.screenshotResult = missingImage ? .text("尚无画面") : ToolResult(content: [.image(data: Data([0]), mimeType: "image/png")])
        let planner = TestPhonePlanner([Self.act()])
        let agent = h.agent(planner)
        agent.start(goal: "点按", deviceID: AIEnv.pixel.id)
        await agent.waitUntilFinished()
        #expect(agent.runs[AIEnv.pixel.id]?.status == .failed)
        #expect(await planner.receivedInputs().isEmpty)
        #expect(h.calls.map(\.name) == ["screenshot"])
        #expect(h.released == [AIEnv.pixel.id])
    }

    @Test func physicalIOSAdvertisesSupportedKeyboardKeysAndRejectsPower() async throws {
        let h = PhoneAgentHarness()
        let phone = DeviceInfo(serial: "ios", platform: .ios, name: "iPhone", state: .connected,
                               connection: .usb, capabilities: [.screenshot, .touch, .keys])
        h.devices[phone.id] = phone
        let planner = TestPhonePlanner([Self.act("press_key", arguments: "{\"key\":\"power\"}")])
        let agent = h.agent(planner)
        agent.start(goal: "返回", deviceID: phone.id)
        await agent.waitUntilFinished()
        #expect(agent.runs[phone.id]?.status == .failed)
        #expect(h.calls.map(\.name) == ["screenshot"])
        let input = try #require(await planner.receivedInputs().first)
        let keyTool = try #require(input.tools.first { $0.name == "press_key" })
        #expect(keyTool.inputSchema["properties"]?["key"]?["enum"] == ["home", "enter", "delete", "tab", "up", "down", "left", "right"])
        let tap = try #require(input.tools.first { $0.name == "tap" })
        #expect(tap.inputSchema["properties"]?["element"] == nil)
        #expect(tap.inputSchema["required"] == ["x", "y"])
    }

    @Test(arguments: ["lock", "disconnect", "capability"])
    func rechecksDeviceAfterInference(change: String) async throws {
        let h = PhoneAgentHarness()
        let planner = TestPhonePlanner([Self.act()], holdFirst: true)
        let agent = h.agent(planner)
        agent.start(goal: "点按", deviceID: AIEnv.pixel.id)
        let waiting = await waitForInference(planner)
        try #require(waiting)
        switch change {
        case "lock": h.locked = true
        case "disconnect": h.devices[AIEnv.pixel.id]?.state = .offline
        default: h.devices[AIEnv.pixel.id]?.capabilities.remove(.touch)
        }
        await planner.resume()
        await agent.waitUntilFinished()
        #expect(agent.runs[AIEnv.pixel.id]?.status == .failed)
        #expect(h.calls.map(\.name) == ["screenshot"])
        #expect(h.released == [AIEnv.pixel.id])
    }

    @Test func cancellationDuringInferenceDiscardsDecisionAndReleasesDevice() async throws {
        let h = PhoneAgentHarness()
        let planner = TestPhonePlanner([Self.act()], holdFirst: true)
        let agent = h.agent(planner)
        agent.start(goal: "点按", deviceID: AIEnv.pixel.id)
        let waiting = await waitForInference(planner)
        try #require(waiting)
        agent.stop()
        #expect(agent.runs[AIEnv.pixel.id]?.status == .stopping)
        await planner.resume()
        await agent.waitUntilFinished()
        #expect(h.calls.map(\.name) == ["screenshot"])
        #expect(agent.runs[AIEnv.pixel.id]?.status == .stopped)
        #expect(agent.activeDeviceID == nil)
        #expect(h.released == [AIEnv.pixel.id])
    }

    @Test(arguments: [false, true])
    func ambiguousActionFailureIsNeverReplayed(throwsError: Bool) async {
        let h = PhoneAgentHarness()
        h.failAction = !throwsError
        h.throwAction = throwsError
        let planner = TestPhonePlanner([Self.act(), Self.act(), Self.done])
        let agent = h.agent(planner)
        agent.start(goal: "点按一次", deviceID: AIEnv.pixel.id)
        await agent.waitUntilFinished()
        #expect(agent.runs[AIEnv.pixel.id]?.status == .failed)
        #expect(!agent.canResume(deviceID: AIEnv.pixel.id))
        agent.resume(deviceID: AIEnv.pixel.id)
        #expect(h.calls.map(\.name) == ["screenshot", "tap"])
        #expect(await planner.receivedInputs().count == 1)
        #expect(h.released == [AIEnv.pixel.id])
    }

    @Test(arguments: [false, true])
    func finalObservationCanCompleteButCannotExceedActionLimit(completes: Bool) async {
        let h = PhoneAgentHarness()
        let planner = TestPhonePlanner([Self.act(), completes ? Self.done : Self.act()])
        let agent = h.agent(planner, maxSteps: 1)
        agent.start(goal: "点按目标", deviceID: AIEnv.pixel.id)
        await agent.waitUntilFinished()
        #expect(agent.runs[AIEnv.pixel.id]?.status == (completes ? .completed : .needsUser))
        #expect(h.calls.map(\.name) == ["screenshot", "tap", "screenshot"])
        #expect(agent.runs[AIEnv.pixel.id]?.steps.count == 1)
        #expect(await planner.receivedInputs().count == 2)
        #expect(h.released == [AIEnv.pixel.id])
    }


    @Test func continuationObservesFreshScreenAndKeepsSuccessfulHistoryWithoutReplay() async throws {
        let h = PhoneAgentHarness()
        let ask = PhoneAgentDecision(kind: .ask, summary: "请完成登录后继续", tool: "", argumentsJSON: "{}")
        let planner = TestPhonePlanner([Self.act(), ask, Self.done])
        let agent = h.agent(planner)
        agent.start(goal: "查看指定聊天", deviceID: AIEnv.pixel.id)
        await agent.waitUntilFinished()
        #expect(agent.canResume(deviceID: AIEnv.pixel.id))
        #expect(agent.runs[AIEnv.pixel.id]?.status == .needsUser)
        #expect(agent.activeDeviceID == nil)
        agent.resume(deviceID: "other-phone", reply: "已登录")
        #expect(h.calls.count == 3)
        agent.resume(deviceID: AIEnv.pixel.id, reply: "已登录")
        await agent.waitUntilFinished()
        #expect(h.calls.map(\.name) == ["screenshot", "tap", "screenshot", "screenshot"])
        #expect(h.calls.allSatisfy { $0.arguments["device"] == .string(AIEnv.pixel.id) })
        #expect(agent.runs[AIEnv.pixel.id]?.steps.count == 1)
        #expect(agent.runs[AIEnv.pixel.id]?.status == .completed)
        #expect(!agent.canResume(deviceID: AIEnv.pixel.id))
        let inputs = await planner.receivedInputs()
        #expect(inputs.count == 3)
        #expect(inputs[2].goal == "查看指定聊天")
        #expect(inputs[2].history.count == 1)
        #expect(inputs[2].history[0].tool == "tap")
        #expect(inputs[2].userReplies == ["已登录"])
        #expect(inputs[2].image != inputs[1].image)
        #expect(h.released == [AIEnv.pixel.id, AIEnv.pixel.id])
    }

    @Test func emptyReplyResumesAfterManualStepAndClearDiscardsContext() async {
        let h = PhoneAgentHarness()
        let ask = PhoneAgentDecision(kind: .ask, summary: "请处理验证码", tool: "", argumentsJSON: "{}")
        let planner = TestPhonePlanner([ask, ask, Self.done])
        let agent = h.agent(planner)
        agent.start(goal: "查看页面", deviceID: AIEnv.pixel.id)
        await agent.waitUntilFinished()
        agent.resume(deviceID: AIEnv.pixel.id)
        await agent.waitUntilFinished()
        let inputs = await planner.receivedInputs()
        #expect(inputs.last?.userReplies == [""])
        #expect(agent.canResume(deviceID: AIEnv.pixel.id))
        agent.clear(deviceID: AIEnv.pixel.id)
        #expect(!agent.canResume(deviceID: AIEnv.pixel.id))
        agent.resume(deviceID: AIEnv.pixel.id)
        #expect(h.calls.count == 2)
    }

    @Test(arguments: ["lock", "disconnect"])
    func continuationRechecksDeviceAvailability(change: String) async {
        let h = PhoneAgentHarness()
        let ask = PhoneAgentDecision(kind: .ask, summary: "请完成登录", tool: "", argumentsJSON: "{}")
        let planner = TestPhonePlanner([ask, Self.act()])
        let agent = h.agent(planner)
        agent.start(goal: "查看页面", deviceID: AIEnv.pixel.id)
        await agent.waitUntilFinished()
        if change == "lock" { h.locked = true } else { h.devices[AIEnv.pixel.id]?.state = .offline }
        agent.resume(deviceID: AIEnv.pixel.id, reply: "已处理")
        #expect(agent.runs[AIEnv.pixel.id]?.status == .failed)
        #expect(!agent.canResume(deviceID: AIEnv.pixel.id))
        #expect(h.calls.map(\.name) == ["screenshot"])
    }

    @Test func continuationAddsActionsWithConsecutiveNumbersAtSegmentLimit() async {
        let h = PhoneAgentHarness()
        let planner = TestPhonePlanner([Self.act(), Self.act(), Self.act(), Self.done])
        let agent = h.agent(planner, maxSteps: 1)
        agent.start(goal: "打开页面", deviceID: AIEnv.pixel.id)
        await agent.waitUntilFinished()
        #expect(agent.canResume(deviceID: AIEnv.pixel.id))
        agent.resume(deviceID: AIEnv.pixel.id)
        await agent.waitUntilFinished()
        #expect(agent.runs[AIEnv.pixel.id]?.status == .completed)
        #expect(agent.runs[AIEnv.pixel.id]?.steps.map(\.number) == [1, 2])
        #expect(h.calls.map(\.name) == ["screenshot", "tap", "screenshot", "screenshot", "tap", "screenshot"])
    }


    @Test(arguments: [false, true])
    func applicationCatalogLoadedOnceAndRetainedAcrossContinuation(fails: Bool) async {
        let h = PhoneAgentHarness()
        h.devices[AIEnv.pixel.id]?.capabilities.insert(.appLaunch)
        if fails { h.catalogResult = .failure(code: "UNSUPPORTED", message: "unavailable", suggestion: nil) }
        let ask = PhoneAgentDecision(kind: .ask, summary: "请补充", tool: "", argumentsJSON: "{}")
        let planner = TestPhonePlanner([Self.act(), ask, Self.done])
        let agent = h.agent(planner)
        agent.start(goal: "打开微信", deviceID: AIEnv.pixel.id)
        await agent.waitUntilFinished()
        agent.resume(deviceID: AIEnv.pixel.id, reply: "已处理")
        await agent.waitUntilFinished()
        #expect(agent.runs[AIEnv.pixel.id]?.status == .completed)
        #expect(h.calls.filter { $0.name == "list_apps" }.count == 1)
        #expect(h.calls.allSatisfy { $0.arguments["device"] == .string(AIEnv.pixel.id) })
        #expect(agent.runs[AIEnv.pixel.id]?.steps.count == 1)
        let inputs = await planner.receivedInputs()
        #expect(inputs.count == 3)
        for input in inputs {
            #expect(input.applicationCatalog == (fails ? nil : "name: WeChat\tbundleID: com.tencent.xin"))
        }
    }

    @Test func runningTaskRejectsConcurrentStartAndClear() async throws {
        let h = PhoneAgentHarness()
        let planner = TestPhonePlanner([Self.done], holdFirst: true)
        let agent = h.agent(planner)
        let other = DeviceInfo(serial: "other", platform: .android, name: "Other", state: .connected,
                               connection: .usb, capabilities: [.screenshot, .touch])
        h.devices[other.id] = other
        agent.start(goal: "第一个任务", deviceID: AIEnv.pixel.id)
        let waiting = await waitForInference(planner)
        try #require(waiting)
        agent.start(goal: "另一个任务", deviceID: other.id)
        agent.start(goal: "替换任务", deviceID: AIEnv.pixel.id)
        agent.clear(deviceID: AIEnv.pixel.id)
        #expect(agent.activeDeviceID == AIEnv.pixel.id)
        #expect(agent.runs[AIEnv.pixel.id]?.goal == "第一个任务")
        #expect(agent.runs[other.id] == nil)
        await planner.resume()
        await agent.waitUntilFinished()
        #expect(h.calls.map(\.name) == ["screenshot"])
        #expect(h.released == [AIEnv.pixel.id])
        agent.clear(deviceID: AIEnv.pixel.id)
        #expect(agent.runs[AIEnv.pixel.id] == nil)
    }
}
