import XCTest
@testable import SimulatorHelper

final class GuestTextInputTests: XCTestCase, @unchecked Sendable {
    @MainActor func testPersistentTransportPreservesUnicodeAndPropagatesGuestFailure() async throws {
        let bridge = GuestTextInput()
        // Exercise real pipes and process lifetime; the shell supplies only the guest protocol.
        try await bridge.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", """
        printf '{"event":"ready"}\\n'
        while IFS= read -r request; do
          case "$request" in
          *clipboard_get*) printf '%s\\n' '{"id":2,"ok":true,"text":"中文🙂\\nnext"}';;
          *quit*) printf '{"id":4,"ok":true}\\n'; exit 0;;
          *unsupported*) printf '{"id":3,"ok":false,"code":"UNSUPPORTED","error":"No focused editor"}\\n';;
          *) printf '{"id":1,"ok":true}\\n';;
          esac
        done
        """])
        let pid = bridge.processIdentifier
        _ = try await bridge.request(command: "text", text: "a")
        let clipboard = try await bridge.request(command: "clipboard_get")
        XCTAssertEqual(clipboard.text, "中文🙂\nnext")
        XCTAssertEqual(bridge.processIdentifier, pid)
        do {
            _ = try await bridge.request(command: "unsupported")
            XCTFail("The guest failure must reach the caller")
        } catch let failure as HelperFailure { XCTAssertEqual(failure.code, "UNSUPPORTED") }
        await bridge.close()
        XCTAssertFalse(bridge.isRunning)
    }

    @MainActor func testUnexpectedEOFDoesNotRestartOrReplayText() async throws {
        let bridge = GuestTextInput()
        try await bridge.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '{\"event\":\"ready\"}\\n'; read -r request; exit 0"])
        do {
            _ = try await bridge.request(command: "text", text: "possibly delivered")
            XCTFail("EOF must not report successful insertion")
        } catch let failure as HelperFailure { XCTAssertEqual(failure.code, "CONNECTION_FAILED") }
        do {
            _ = try await bridge.request(command: "text", text: "must not replay")
            XCTFail("The broken connection must remain broken")
        } catch let failure as HelperFailure { XCTAssertEqual(failure.code, "CONNECTION_FAILED") }
        await bridge.close()
    }
}

extension GuestTextInputTests {
    @MainActor func testAlreadyCancelledRequestDoesNotSendText() async throws {
        let bridge = GuestTextInput()
        try await bridge.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", """
        printf '{"event":"ready"}\\n'
        while IFS= read -r request; do
          case "$request" in
          *quit*) printf '{"id":1,"ok":true}\\n'; exit 0;;
          *) exit 9;;
          esac
        done
        """])
        let operation = Task { @MainActor in try await bridge.request(command: "text", text: "must not send") }
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled input must not be sent") }
        catch is CancellationError { }
        XCTAssertTrue(bridge.isRunning)
        await bridge.close()
    }

    @MainActor func testStoppedReaderCannotBlockLargeWriteOrClose() async throws {
        let bridge = GuestTextInput()
        try await bridge.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '{\"event\":\"ready\"}\\n'; exec sleep 30"])
        let start = ContinuousClock.now
        let operation = Task { @MainActor in try await bridge.request(command: "text", text: String(repeating: "x", count: 2 * 1024 * 1024)) }
        try await Task.sleep(for: .milliseconds(50))
        // If the pipe write blocks MainActor this sleep and cancellation cannot run.
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Interrupted delivery must fail") }
        catch { }
        await bridge.close()
        XCTAssertLessThan(start.duration(to: .now), .seconds(4))
    }
}

extension GuestTextInputTests {
    @MainActor func testStoppedReaderLargeWriteTimesOut() async throws {
        let bridge = GuestTextInput()
        try await bridge.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '{\"event\":\"ready\"}\\n'; exec sleep 30"])
        let start = ContinuousClock.now
        do {
            _ = try await bridge.request(command: "text", text: String(repeating: "x", count: 2 * 1024 * 1024))
            XCTFail("A stopped guest must time out without reporting insertion")
        } catch let failure as HelperFailure { XCTAssertEqual(failure.code, "CONNECTION_FAILED") }
        XCTAssertLessThan(start.duration(to: .now), .seconds(4))
        await bridge.close()
        XCTAssertFalse(bridge.isRunning)
    }

    @MainActor func testStartupFailurePreservesUnsupportedCode() async throws {
        let bridge = GuestTextInput()
        do {
            try await bridge.start(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "printf '{\"id\":0,\"ok\":false,\"code\":\"UNSUPPORTED\",\"error\":\"Runtime unavailable\"}\\n'; exit 1"])
            XCTFail("Unsupported guest startup must fail clearly")
        } catch let failure as HelperFailure { XCTAssertEqual(failure.code, "UNSUPPORTED") }
        await bridge.close()
    }
}
