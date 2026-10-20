import AndroidDriver
import Testing
import SwiftUI
@testable import Tandem

@MainActor
@Suite struct RomSnapshotTests {
    @Test func bannerAndSheet() throws {
        let banner = try SnapshotRenderer.render("rom-banner", size: CGSize(width: 640, height: 60)) {
            RomBannerView(guide: .forManufacturer("xiaomi"), onReconnect: {}, onDismiss: {})
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(Theme.canvas)
        }
        #expect(banner.width == 1280 && banner.height == 120)
        let sheet = try SnapshotRenderer.render("rom-steps-sheet", size: CGSize(width: 480, height: 620)) {
            RomStepsSheet(detected: .forManufacturer("xiaomi"), onLater: {}, onRecheck: {})
        }
        #expect(sheet.width == 960 && sheet.height == 1240)
    }
}
