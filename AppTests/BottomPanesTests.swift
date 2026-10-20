import CoreGraphics
import Foundation
import Testing
@testable import Tandem

private func item(name: String = "Pixel 8", date: Date = Date(timeIntervalSince1970: 1_760_000_000), kind: CaptureItem.Kind = .screenshot) -> CaptureItem {
    CaptureItem(
        id: UUID(), kind: kind, url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).png"), deviceName: name, date: date,
        duration: kind == .recording ? 65 : nil, fileSize: 1, thumbnailPNG: nil)
}

private func entry(device: String, title: String, failure: String?, source: ActivitySource = .user) -> ActivityEntry {
    ActivityEntry(id: UUID(), date: Date(), source: source, deviceName: device, title: title, failure: failure)
}

@MainActor
@Suite struct BottomPanesTests {
    @Test func tileLabelAndActivityLine() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 15, minute: 30))!
        #expect(CaptureText.tileLabel(item(name: "Pixel 8", date: date)) == "Pixel 8 · 15:30")
        #expect(ActivityText.line(entry(device: "Pixel 8", title: "截图", failure: nil)) == "Pixel 8 · 截图")
        #expect(ActivityText.line(entry(device: "Pixel 8", title: "截图", failure: "超时")) == "Pixel 8 · 截图：超时")
        #expect(ActivitySource.user.chipTone == .accent && ActivitySource.ai.chipTone == .ai && ActivitySource.ai.chipTitle == "AI")
        #expect(ActivitySource.user.chipTitle == "你")
    }

    @Test func tileLabelUsesGivenTimeZone() {
        // 2025-10-09 08:53:20 UTC
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        #expect(CaptureText.tileLabel(item(name: "P", date: date), timeZone: TimeZone(identifier: "UTC")!) == "P · 08:53")
        #expect(CaptureText.tileLabel(item(name: "P", date: date), timeZone: TimeZone(identifier: "Asia/Shanghai")!) == "P · 16:53")
    }

    @Test func thumbSizeKeepsAspect() {
        #expect(CaptureText.thumbSize(pixelWidth: 1080, pixelHeight: 2400, box: 92) == CGSize(width: 41.4, height: 92))
        #expect(CaptureText.thumbSize(pixelWidth: 2400, pixelHeight: 1080, box: 92) == CGSize(width: 92, height: 41.4))
        #expect(CaptureText.thumbSize(pixelWidth: nil, pixelHeight: nil, box: 92) == CGSize(width: 41, height: 92))
        #expect(CaptureText.thumbSize(pixelWidth: 0, pixelHeight: 100, box: 92) == CGSize(width: 41, height: 92))
    }

    @Test func freshForThreeSeconds() {
        let date = Date(timeIntervalSince1970: 1_760_000_000)
        #expect(CaptureText.isFresh(date: date, now: date.addingTimeInterval(2.9)) && !CaptureText.isFresh(date: date, now: date.addingTimeInterval(3)))
    }
}

@MainActor
@Suite struct RecentStripKeysTests {
    private let a = item(), b = item(), c = item()

    @Test func spacePreviewsSelectedExistingFile() {
        let keys = RecentStripKeys(items: [a, b, c], selectedID: b.id)
        #expect(keys.space() == .preview(b.url, 1))
    }

    @Test func spaceDoesNothingWithoutSelectionOrFile() {
        #expect(RecentStripKeys(items: [a, b], selectedID: nil).space() == .none)
        #expect(RecentStripKeys(items: [a, b], selectedID: b.id, missingIDs: [b.id]).space() == .none)
        // 选中项已不在列表里
        #expect(RecentStripKeys(items: [a], selectedID: b.id).space() == .none)
    }

    @Test func copySelectedExistingFile() {
        #expect(RecentStripKeys(items: [a, b], selectedID: a.id).copy() == .copy(a))
        #expect(RecentStripKeys(items: [a, b], selectedID: nil).copy() == .none)
        #expect(RecentStripKeys(items: [a, b], selectedID: a.id, missingIDs: [a.id]).copy() == .none)
    }

    @Test func moveStaysInBounds() {
        var keys = RecentStripKeys(items: [a, b, c], selectedID: b.id)
        keys.move(1)
        #expect(keys.selectedID == c.id && keys.selectedIndex == 2)
        keys.move(1)
        #expect(keys.selectedID == c.id)
        keys.move(-1)
        keys.move(-1)
        keys.move(-1)
        #expect(keys.selectedID == a.id && keys.selectedIndex == 0)
    }

    @Test func moveWithoutSelectionPicksEnd() {
        var right = RecentStripKeys(items: [a, b, c], selectedID: nil)
        right.move(1)
        #expect(right.selectedID == a.id)
        var left = RecentStripKeys(items: [a, b, c], selectedID: nil)
        left.move(-1)
        #expect(left.selectedID == c.id)
        var empty = RecentStripKeys(items: [], selectedID: nil)
        empty.move(1)
        #expect(empty.selectedID == nil)
    }

    @Test func deletedTileCanBeSelected() {
        var keys = RecentStripKeys(items: [a, b], selectedID: a.id, missingIDs: [b.id])
        keys.move(1)
        #expect(keys.selectedID == b.id)
        #expect(keys.space() == .none && keys.copy() == .none)
    }

    @Test func escapeClearsSelection() {
        var keys = RecentStripKeys(items: [a, b], selectedID: a.id)
        keys.escape()
        #expect(keys.selectedID == nil)
    }

    @Test func removedSelectionIsCleared() {
        var keys = RecentStripKeys(items: [a, b], selectedID: b.id)
        keys.update(items: [a])
        #expect(keys.selectedID == nil)
        var kept = RecentStripKeys(items: [a, b], selectedID: a.id)
        kept.update(items: [c, a])
        #expect(kept.selectedID == a.id && kept.selectedIndex == 1)
        kept.update(items: [])
        #expect(kept.selectedID == nil)
    }
}
