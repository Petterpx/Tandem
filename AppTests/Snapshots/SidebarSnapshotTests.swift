import Testing
import SwiftUI
import DeviceCore
@testable import Tandem

@MainActor
@Suite struct SidebarSnapshotTests {
    @Test func sidebar() throws {
        let rows: [(DeviceInfo, selected: Bool, recording: Bool, popped: Bool, locked: Bool)] = [
            (DeviceInfo(serial: "a", platform: .android, name: "Pixel 8", state: .connected, connection: .usb), true, false, true, false),
            (DeviceInfo(serial: "b", platform: .android, name: "Galaxy S10", state: .connected, connection: .wifi), false, true, false, true),
            (DeviceInfo(serial: "c", platform: .android, name: "Redmi Note", state: .unauthorized, connection: .usb), false, false, false, false),
        ]
        let image = try SnapshotRenderer.render("sidebar", size: CGSize(width: 232, height: 520)) {
            // 列表区用普通 VStack 代替 ScrollView（ImageRenderer 不渲染 AppKit 视图）
            SidebarChrome(count: rows.count, onPair: {}) {
                VStack(spacing: 2) {
                    ForEach(rows, id: \.0.id) { row in
                        DeviceRowView(device: row.0, isSelected: row.selected, isRecording: row.recording,
                                      isPopped: row.popped, isLocked: row.locked, onPop: nil)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        #expect(image.width == 464 && image.height == 1040)
    }
}
