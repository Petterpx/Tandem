import Testing
import SwiftUI
@testable import Tandem

@MainActor
@Suite struct RightPanelSnapshotTests {
    @Test func shell() throws {
        let image = try SnapshotRenderer.render("right-panel-shell", size: CGSize(width: 372, height: 520)) {
            VStack(alignment: .leading, spacing: 0) {
                RightPanelHeader(deviceName: "Pixel 8", tabs: RightTab.visible(hasFiles: true), selection: .constant(.quickActions))
                VStack(alignment: .leading, spacing: Metrics.sectionSpacing) {
                    QuickSectionChrome(title: "网络", unsupported: true, collapsed: false, onToggle: {}, onRefresh: nil) {
                        VStack(spacing: 0) { CardRow("Wi-Fi") { Chip("开", tone: .success) } }.tandemCard()
                    }
                    QuickSectionChrome(title: "应用", unsupported: false, collapsed: false, onToggle: {}, onRefresh: {}) {
                        VStack(spacing: 0) { CardRow("无线调试", subtitle: "端口 5555") { Chip("开", tone: .success) } }.tandemCard()
                    }
                    CapabilityOverviewCard(deviceName: "Pixel 8", rows: [
                        (title: "投屏", supported: true), (title: "网络", supported: true), (title: "Shell", supported: false),
                    ])
                }
                .padding(EdgeInsets(top: 14, leading: 16, bottom: 20, trailing: 16))
                Spacer(minLength: 0)
            }
            .background(Theme.panel)
        }
        #expect(image.width == 744 && image.height == 1040)
    }
}
