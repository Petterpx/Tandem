import AppKit
import CoreGraphics
import Foundation
import MediaKit
import SwiftUI
import Testing
@testable import Tandem

@MainActor
@Suite struct BottomPanesSnapshotTests {
    private func makeStore() async throws -> CaptureStore {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("tandem-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        // 依次为：已删除的录屏 15:21、录屏 15:25、截图 15:30
        var dates = [21, 25, 30].map {
            Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 15, minute: $0))!
        }
        let store = CaptureStore(
            pasteboard: MacPasteboard(NSPasteboard(name: .init(UUID().uuidString))), defaults: defaults, home: home,
            now: { dates.removeFirst() })
        let thumb = AIEnv.png(width: 480, height: 1066)
        let missing = home.appendingPathComponent("gone.mp4")
        _ = store.addRecording(
            RecordingSummary(url: missing, duration: 12, canvasSize: CGSize(width: 480, height: 1066), fileSize: 1, thumbnailPNG: thumb),
            deviceName: "Pixel 8")
        let video = home.appendingPathComponent("video.mp4")
        try Data([0]).write(to: video)
        _ = store.addRecording(
            RecordingSummary(url: video, duration: 65, canvasSize: CGSize(width: 480, height: 1066), fileSize: 1, thumbnailPNG: thumb),
            deviceName: "Pixel 8")
        _ = try await store.saveScreenshot(.png(AIEnv.png(width: 1080, height: 2400)), deviceName: "Pixel 8")
        return store
    }

    private func makeLog() -> ActivityLog {
        let log = ActivityLog()
        let base = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 15, minute: 32, second: 8))!
        log.append(ActivityEntry(id: UUID(), date: base.addingTimeInterval(-120), source: .user, deviceName: "Pixel 8", title: "截图", failure: "保存目录不可写"))
        log.append(ActivityEntry(id: UUID(), date: base.addingTimeInterval(-60), source: .ai, deviceName: "Pixel 8", title: "截图", failure: nil))
        log.append(ActivityEntry(id: UUID(), date: base, source: .user, deviceName: "Pixel 8", title: "结束录屏", failure: nil))
        return log
    }

    @Test func bottomRow() async throws {
        let store = try await makeStore()
        let log = makeLog()
        let screenshotDate = try #require(store.recent.first?.date)
        let image = try SnapshotRenderer.render("bottom-row", size: CGSize(width: 1000, height: 168)) {
            // ScrollView 换成普通容器（ImageRenderer 不渲染 AppKit 视图）
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    RecentCapturesHeader(count: store.recent.count, onClear: {})
                    RecentTiles(items: store.recent, store: store, selectedID: store.recent[1].id, now: screenshotDate.addingTimeInterval(1))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                }
                VStack(spacing: 0) {
                    ActivityLogHeader(isEmpty: log.entries.isEmpty, onClear: {})
                    ActivityRows(entries: log.entries)
                    Spacer(minLength: 0)
                }
                .frame(width: Metrics.panelWidth)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
            }
        }
        #expect(image.width == 2000 && image.height == 336)
    }

    @Test func hoveredTile() async throws {
        let store = try await makeStore()
        let item = try #require(store.recent.first)
        let image = try SnapshotRenderer.render("bottom-tile-hovered", size: CGSize(width: 140, height: 150)) {
            RecentTile(item: item, store: store, exists: true, hovered: true)
                .padding(.top, 14)
                .frame(maxHeight: .infinity, alignment: .top)
        }
        #expect(image.width == 280 && image.height == 300)
    }
}
