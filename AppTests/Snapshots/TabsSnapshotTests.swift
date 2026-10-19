import AppKit
import DeviceCore
import Foundation
import SwiftUI
import Testing
@testable import Tandem

@MainActor
@Suite struct TabsSnapshotTests {
    @Test func clipboardAndAI() async throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-\(UUID().uuidString)")
        defaults.set(dir.path, forKey: "recordingDirectory")
        defaults.set(dir.path, forKey: "screenshotDirectory")
        let raw = NSPasteboard(name: .init(UUID().uuidString))
        raw.clearContents()
        raw.setString("来自 Mac 的文本", forType: .string)
        let model = AppModel(defaults: defaults)
        let services = AppServices(model: model, pasteboard: MacPasteboard(raw), defaults: defaults)
        services.connect()

        let fake = FakeDeviceSession()
        fake.clipboardResult = .success("https://example.com/手机上复制的链接")
        _ = try await services.clipboard.read("s1", session: fake)
        try await services.clipboard.write("s1", text: "写入手机的一段较长文本，用来检查单行省略是否生效\n第二行", paste: false, session: fake)

        let clipboard = try SnapshotRenderer.render("tabs-clipboard", size: CGSize(width: 372, height: 760)) {
            ClipboardTabContent(
                commands: services.commands, clipboard: services.clipboard, deviceID: "s1",
                input: .constant(""), macText: "来自 Mac 的文本")
                .background(Theme.panel)
        }
        let ai = try SnapshotRenderer.render("tabs-ai", size: CGSize(width: 372, height: 760)) {
            AITabContent(services: services, deviceID: "s1")
                .background(Theme.panel)
        }
        #expect(clipboard.width == 744 && clipboard.height == 1520)
        #expect(ai.width == 744 && ai.height == 1520)
    }
}
