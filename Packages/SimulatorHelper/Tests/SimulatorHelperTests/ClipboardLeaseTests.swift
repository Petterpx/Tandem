import XCTest
@testable import SimulatorHelper

@MainActor
final class ClipboardLeaseTests: XCTestCase {
    func testASecondWriterTimesOutUntilTheFirstLeaseIsReleased() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "clipboard.lock").path
        do {
            let first = try await ClipboardLease.acquire(path: path)
            do {
                _ = try await ClipboardLease.acquire(path: path, timeout: .milliseconds(70))
                XCTFail("Another writer acquired the occupied lease")
            } catch let failure as HelperFailure { XCTAssertEqual(failure.code, "TIMEOUT") }
            withExtendedLifetime(first) {}
        }
        let next = try await ClipboardLease.acquire(path: path, timeout: .milliseconds(70))
        withExtendedLifetime(next) {}
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testSymlinkLockCannotRedirectWritesToAnotherFile() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appending(path: "target")
        try Data("unchanged".utf8).write(to: target)
        let link = dir.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        do { _ = try await ClipboardLease.acquire(path: link.path); XCTFail("Symlink accepted as a lock") }
        catch let failure as HelperFailure { XCTAssertEqual(failure.code, "CONNECTION_FAILED") }
        XCTAssertEqual(try Data(contentsOf: target), Data("unchanged".utf8))
    }

    func testCancelledWaiterDoesNotKeepTheLease() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appending(path: "clipboard.lock").path
        do {
            let first = try await ClipboardLease.acquire(path: path)
            let waiter = Task { try await ClipboardLease.acquire(path: path) }
            waiter.cancel()
            do { _ = try await waiter.value; XCTFail("Cancelled waiter acquired the lock") }
            catch { XCTAssertTrue(error is CancellationError) }
            withExtendedLifetime(first) {}
        }
        let next = try await ClipboardLease.acquire(path: path, timeout: .milliseconds(70))
        withExtendedLifetime(next) {}
    }
}
