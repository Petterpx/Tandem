import DeviceCore
import SwiftUI
import Testing
@testable import Tandem

@MainActor
@Suite struct QuickSectionsSnapshotTests {
    @Test func networkAndApps() async throws {
        let actions = RecordingActions()
        let dev = QuickEnv.device("A")
        let env = QuickEnv.make([(dev, actions)])
        await env.model.refreshAll(dev.id)
        let model = env.model
        let id = dev.id

        let image = try SnapshotRenderer.render("quick-network-apps", size: CGSize(width: 372, height: 640)) {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                QuickSection(section: .network, model: model, deviceID: id) { NetworkSection(model: model, deviceID: id) }
                QuickSection(section: .apps, model: model, deviceID: id) { AppsSection(model: model, deviceID: id, openLogs: { _ in }) }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .background(Theme.panel)
        }
        #expect(image.width == 744 && image.height == 1280)
    }

    @Test func linksSystemDevCustom() async throws {
        let actions = RecordingActions()
        actions.shellResult = ShellResult(stdout: "line one\nline two\n", stderr: "", exitCode: 0)
        actions.devOptionsResult = DevOptions(showTouches: true, layoutBounds: false, stayAwake: true, animationScale: 1)
        actions.systemSettingsResult = SystemSettings(darkMode: false, fontScale: 1.0, appLocale: "", appLocaleSupported: true)
        let dev = QuickEnv.device("A")
        let env = QuickEnv.make([(dev, actions)])
        let model = env.model
        let id = dev.id
        for url in ["https://example.com/a/very/long/path/that/keeps/going", "myapp://home", "https://tandem.dev"] {
            env.store.recordURL(url)
        }
        env.store.addCommand(name: "重启 SystemUI", command: "pkill -f com.android.systemui")
        env.store.addCommand(name: "列出进程", command: "ps -A")
        await model.runCustom(id, env.store.commands[1], package: nil)
        await model.refreshAll(id)

        let image = try SnapshotRenderer.render("quick-links-system-dev-custom", size: CGSize(width: 372, height: 900)) {
            VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                QuickSection(section: .openURL, model: model, deviceID: id) { OpenURLSection(model: model, deviceID: id) }
                QuickSection(section: .system, model: model, deviceID: id) { SystemSection(model: model, deviceID: id) }
                QuickSection(section: .devOptions, model: model, deviceID: id) { DevOptionsSection(model: model, deviceID: id) }
                QuickSection(section: .custom, model: model, deviceID: id) { CustomCommandsSection(model: model, deviceID: id) }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16))
            .background(Theme.panel)
        }
        #expect(image.width == 744 && image.height == 1800)
    }
}
