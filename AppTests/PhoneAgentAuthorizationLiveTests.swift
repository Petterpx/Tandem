import AppKit
import ControlProtocol
import Foundation
import Testing
@testable import Tandem

/// Opt-in model behavior check. Only the synthetic image reaches the planner;
/// this suite has no device/session access and never executes its decision.
@MainActor @Suite struct PhoneAgentAuthorizationLiveTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TANDEM_LIVE_AUTHORIZATION_CHECK"] == "1"))
    func ordinarySpecifiedMessageChoosesSendWithoutAnotherConfirmation() async throws {
        let executable = try #require(PhoneAgentSettings.discoverCodex(), "需要已登录的 Codex CLI")
        let model = ProcessInfo.processInfo.environment["TANDEM_LIVE_PLANNER_MODEL"] ?? "gpt-6.1-sol"
        let configuration = PhoneAgentConfiguration(
            provider: .codex, model: model, baseURL: "", apiKey: "", codexPath: executable)
        let tap = ToolDescriptor(
            name: "tap", description: "点按截图像素坐标，原点在左上角。",
            inputSchema: [
                "type": "object", "additionalProperties": false,
                "properties": ["x": ["type": "number"], "y": ["type": "number"]],
                "required": ["x", "y"],
            ])
        let input = PhoneAgentInput(
            goal: "打开微信，给测试联系人发消息，说这个消息来自cli", deviceName: "Synthetic iPhone", platform: "ios",
            tools: [tap], image: try syntheticChatPNG(), mimeType: "image/png",
            screenDescription: "合成 UI 测试图，无真实聊天或设备。当前已确认为联系人测试联系人的微信聊天，输入框已填入这个消息来自cli，尚未发送。以附图像素为准。",
            history: [], step: 1)
        let started = ContinuousClock.now
        let decision = try await PhoneAgentPlanner().decide(input, configuration: configuration)
        print("Synthetic phone planner: \(model), \(ContinuousClock.now - started)")
        #expect(decision.kind == .act, "明确普通消息应继续执行：\(decision.summary)")
        #expect(decision.tool == "tap")
        let arguments = try JSONDecoder().decode(JSONValue.self, from: Data(decision.argumentsJSON.utf8))
        let x = try #require(arguments["x"]?.doubleValue)
        let y = try #require(arguments["y"]?.doubleValue)
        #expect((490.0...575.0).contains(x), "点按应位于合成发送按钮内")
        #expect((1170.0...1230.0).contains(y), "点按应位于合成发送按钮内")
    }

    /// Bitmap coordinates are exact pixels. AppKit draws bottom-up; every
    /// rectangle is converted from the planner's top-left coordinate system.
    private func syntheticChatPNG() throws -> Data {
        let width = 586
        let height = 1280
        let bitmap = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        func rect(_ x: CGFloat, _ top: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: x, y: CGFloat(height) - top - h, width: w, height: h)
        }
        func fill(_ rectangle: NSRect, color: NSColor, radius: CGFloat = 0) {
            color.setFill()
            NSBezierPath(roundedRect: rectangle, xRadius: radius, yRadius: radius).fill()
        }
        func text(_ value: String, in rectangle: NSRect, size: CGFloat, centered: Bool = false,
                  color: NSColor = .black, bold: Bool = false) {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = centered ? .center : .left
            (value as NSString).draw(in: rectangle, withAttributes: [
                .font: NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular),
                .foregroundColor: color, .paragraphStyle: paragraph,
            ])
        }
        fill(rect(0, 0, 586, 1280), color: NSColor(white: 0.94, alpha: 1))
        fill(rect(0, 0, 586, 135), color: NSColor(white: 0.98, alpha: 1))
        text("微信", in: rect(24, 24, 100, 34), size: 22)
        text("测试联系人", in: rect(160, 66, 266, 48), size: 32, centered: true, bold: true)
        text("当前聊天：测试联系人", in: rect(180, 170, 226, 35), size: 20,
             centered: true, color: .darkGray)
        fill(rect(0, 1148, 586, 132), color: NSColor(white: 0.98, alpha: 1))
        fill(rect(18, 1170, 458, 60), color: .white, radius: 8)
        text("这个消息来自cli", in: rect(30, 1184, 434, 40), size: 25)
        fill(rect(490, 1170, 85, 60), color: NSColor(red: 0.04, green: 0.68, blue: 0.30, alpha: 1), radius: 8)
        text("发送", in: rect(490, 1184, 85, 40), size: 25, centered: true, color: .white, bold: true)
        context.flushGraphics()
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
