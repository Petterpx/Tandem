import Foundation
import Testing
@testable import Tandem

@MainActor
@Suite struct AILocksTests {
    @Test func locksPersistAcrossInstances() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let first = AILocks(defaults: defaults)
        first.setLocked("a", true)
        let second = AILocks(defaults: defaults)
        #expect(second.isLocked("a"))
        #expect(!second.isLocked("b"))
        second.setLocked("a", false)
        #expect(!AILocks(defaults: defaults).isLocked("a"))
    }
}
