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
}
