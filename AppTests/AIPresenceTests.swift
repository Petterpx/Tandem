import DeviceCore
import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct AIPresenceTests {
    @Test func showReplacesAndExpires() async throws {
        let presence = AIPresence()
        presence.show("a", .tap(NormalizedPoint(x: 0.1, y: 0.2)), label: "第一条")
        presence.show("a", .label, label: "第二条")
        #expect(presence.indicators["a"]?.label == "第二条")
        #expect(presence.indicators.count == 1)
        try await Task.sleep(for: .milliseconds(2100))
        #expect(presence.indicators["a"] == nil)
    }

    @Test func staleTimerDoesNotRemoveNewerIndicator() async throws {
        let presence = AIPresence()
        presence.show("a", .label, label: "一")
        try await Task.sleep(for: .milliseconds(1500))
        presence.show("a", .label, label: "二")
        try await Task.sleep(for: .milliseconds(600))
        #expect(presence.indicators["a"]?.label == "二")
    }

    @Test func touchRecordsTime() {
        let t = Date(timeIntervalSince1970: 1000)
        let presence = AIPresence(now: { t })
        presence.touch("a")
        #expect(presence.lastUsed["a"] == t)
    }

    @Test func clearRemovesIndicator() {
        let presence = AIPresence()
        presence.show("a", .label, label: "x")
        presence.clearIndicator("a")
        #expect(presence.indicators["a"] == nil)
    }
}
