import XCTest
@testable import SimulatorHelper

final class ProtocolTests: XCTestCase {
    func request(_ phase: String, _ pointer: String, x: Double = 0.5, y: Double = 0.25) -> Request {
        Request(id: 1, command: "touch", phase: phase, x: x, y: y, pointer: pointer)
    }
    func testTouchOwnerCannotBeReleasedOrMovedByAnotherSource() throws {
        var state = TouchOwnership()
        _ = try state.apply(request("down", "finger"))
        XCTAssertThrowsError(try state.apply(request("up", "ai")))
        XCTAssertThrowsError(try state.apply(request("move", "ai")))
        XCTAssertEqual(state.owner, "finger")
        _ = try state.apply(request("move", "finger", x: 0.75))
        XCTAssertEqual(state.point, CGPoint(x: 0.75, y: 0.25))
        _ = try state.apply(request("up", "finger"))
        XCTAssertNil(state.owner)
    }
    func testTouchRejectsInvalidCoordinatesAndUnstartedMovesWithoutClaimingOwnership() throws {
        var state = TouchOwnership()
        for x in [-0.01, 1.01, .nan, .infinity] {
            XCTAssertThrowsError(try state.apply(request("down", "finger", x: x)))
        }
        XCTAssertThrowsError(try state.apply(request("move", "finger")))
        XCTAssertThrowsError(try state.apply(request("down", "unknown")))
        XCTAssertNil(state.owner)
        _ = try state.apply(request("down", "ai", x: 0, y: 1))
        XCTAssertEqual(state.point, CGPoint(x: 0, y: 1))
    }
    func testTouchMovementDistinguishesTapFromDragAndResetsForNextGesture() throws {
        var state = TouchOwnership()
        _ = try state.apply(request("down", "finger"))
        XCTAssertFalse(state.hasMoved)
        _ = try state.apply(request("move", "finger"))
        XCTAssertFalse(state.hasMoved, "A repeated position is still a tap")
        _ = try state.apply(request("move", "finger", x: 0.75))
        XCTAssertTrue(state.hasMoved)
        _ = try state.apply(request("move", "finger", x: 0.5))
        XCTAssertTrue(state.hasMoved, "Returning to the origin does not undo the drag")
        _ = try state.apply(request("up", "finger"))
        XCTAssertFalse(state.hasMoved)
        _ = try state.apply(request("down", "finger"))
        XCTAssertFalse(state.hasMoved)
    }
    func testRejectedTouchCannotChangeOwnersMovementClassification() throws {
        var state = TouchOwnership()
        _ = try state.apply(request("down", "finger"))
        XCTAssertThrowsError(try state.apply(request("move", "ai", x: 0.75)))
        XCTAssertFalse(state.hasMoved)
        XCTAssertEqual(state.point, CGPoint(x: 0.5, y: 0.25))
        _ = try state.apply(request("move", "finger", x: 0.75))
        XCTAssertThrowsError(try state.apply(request("up", "ai")))
        XCTAssertTrue(state.hasMoved)
        XCTAssertEqual(state.owner, "finger")
        _ = try state.apply(request("up", "finger"))
        _ = try state.apply(request("down", "ai"))
        XCTAssertFalse(state.hasMoved)
        _ = try state.apply(request("move", "ai", y: 0.5))
        XCTAssertTrue(state.hasMoved)
    }
}

final class LineFramerTests: XCTestCase {
    func testSplitCoalescedAndCRLFLinesPreserveUnicodeBytes() throws {
        var framer = LineFramer(limit: 100)
        let bytes = Data("{\"text\":\"中文\"}\r\n{}\n".utf8)
        XCTAssertEqual(try framer.append(bytes.prefix(12)), [])
        let lines = try framer.append(bytes.dropFirst(12))
        XCTAssertEqual(lines.map { String(decoding: $0, as: UTF8.self) }, ["{\"text\":\"中文\"}", "{}"])
    }
    func testLineLimitAppliesToCompleteAndPartialMessages() throws {
        var framer = LineFramer(limit: 4)
        XCTAssertThrowsError(try framer.append(Data("12345\n".utf8)))
        var partial = LineFramer(limit: 4)
        XCTAssertEqual(try partial.append(Data("1234".utf8)), [])
        XCTAssertThrowsError(try partial.append(Data("5".utf8)))
    }
}

final class PasteMenuTests: XCTestCase {
    func item(_ label: String = "Paste", id: String? = nil, native: Bool = true, x: Double = 10) -> MenuItem {
        MenuItem(label: label, identifier: id, role: "Button", frame: CGRect(x: x, y: 50, width: 80, height: 40), isNativeMenu: native)
    }
    func testNativePasteRequiresStableGeometryAndExcludesPreexistingAppButtons() {
        let now = ContinuousClock.now
        var menu = PasteMenu()
        let decoy = item(id: "app-paste", native: false)
        let native = item("貼上", x: 20)
        XCTAssertNil(menu.observe([decoy, native], baseline: [decoy], at: now))
        XCTAssertEqual(menu.observe([decoy, native], baseline: [decoy], at: now.advanced(by: .seconds(1))), native)
        let moved = item("貼上", x: 40)
        XCTAssertNil(menu.observe([moved], baseline: [decoy], at: now.advanced(by: .seconds(2))))
        XCTAssertEqual(menu.observe([moved], baseline: [decoy], at: now.advanced(by: .seconds(3))), moved)
    }
    func testAmbiguousOrAppOwnedPasteNeverBecomesActionable() {
        let now = ContinuousClock.now
        var menu = PasteMenu()
        let existing = item(id: "existing")
        for items in [[existing], [item(native: false)], [item(x: 10), item(x: 90)]] {
            XCTAssertNil(menu.observe(items, baseline: [existing], at: now))
            XCTAssertNil(menu.observe(items, baseline: [existing], at: now.advanced(by: .seconds(2))))
        }
    }
}

import FBSimulatorAX

final class MenuProvenanceTests: XCTestCase {
    func node(_ role: String, label: String = "", id: String? = nil, keyboard: Bool = false, children: [AccessibilityDocumentElement] = []) -> AccessibilityDocumentElement {
        var node = AccessibilityDocumentElement(children: children)
        node.type = .some(role)
        node.label = .some(label)
        node.identifier = .some(id)
        node.frame = .some(.init(x: 10, y: 20, width: 80, height: 40))
        node.traits = .some(keyboard ? ["KeyboardKey"] : ["Button"])
        return node
    }
    func testAnonymousSinglePasteButtonDoesNotProveSystemMenuProvenance() {
        let appGroup = node("Group", children: [node("Button", label: "Paste")])
        XCTAssertFalse(MenuNode(appGroup).items().contains { $0.isNativeMenu })
    }
    func testAnonymousAppGroupWithPasteAndUnrelatedActionIsNotNativeMenu() {
        let app = node("Group", children: [node("Button", label: "Paste"), node("Button", label: "Run")])
        XCTAssertFalse(MenuNode(app).items().contains { $0.isNativeMenu })
    }
    func testAnonymousEditingGroupIsRecognizedButAppControlsAndKeyboardAreExcluded() {
        let paste = node("Button", label: "Paste")
        let select = node("Button", label: "Select All")
        let system = node("Group", children: [paste, select])
        XCTAssertEqual(MenuNode(system).items().filter { $0.isNativeMenu }.count, 2)
        let identified = node("Group", id: "app-toolbar", children: [paste, select])
        XCTAssertFalse(MenuNode(identified).items().contains { $0.isNativeMenu })
        let keyboard = node("Group", children: [node("Button", label: "Paste", keyboard: true), select])
        XCTAssertFalse(MenuNode(keyboard).items().contains { $0.isNativeMenu })
    }
}

final class TouchDeliveryStateTests: XCTestCase {
    private func request(_ phase: String, x: Double = 0.5) -> Request {
        Request(id: 1, command: "touch", phase: phase, x: x, y: 0.5, pointer: "finger")
    }

    func testFirstDisplaySnapshotDoesNotCancelPendingInitialTouch() throws {
        var state = TouchDeliveryState()
        let firstDown = try state.prepare(request("down"))
        _ = state.observeDisplayChange(from: nil, to: 7)
        XCTAssertNoThrow(try state.commit(firstDown))
        XCTAssertEqual(state.owner, "finger")
    }

    func testLaterDisplaySnapshotStillInvalidatesPendingTouch() throws {
        var state = TouchDeliveryState()
        _ = state.observeDisplayChange(from: nil, to: 7)
        try state.commit(state.prepare(request("down")))
        let move = try state.prepare(request("move", x: 0.9))
        _ = state.observeDisplayChange(from: 7, to: 8)
        XCTAssertThrowsError(try state.commit(move))
        XCTAssertNil(state.owner)
    }

    func testCancelledDisplayCannotCommitAnAlreadyAcknowledgedDown() throws {
        var state = TouchDeliveryState()
        let pendingDown = try state.prepare(request("down"))
        // Native ACK is queued, then a display change releases that native operation.
        state.invalidateHuman()
        XCTAssertThrowsError(try state.commit(pendingDown))
        XCTAssertNil(state.owner)
        XCTAssertThrowsError(try state.prepare(request("move")))
    }

    func testOldMoveCannotOverwriteANewDisplayContactAfterCancellation() throws {
        var state = TouchDeliveryState()
        try state.commit(state.prepare(request("down")))
        let pendingMove = try state.prepare(request("move", x: 0.9))
        state.invalidateHuman()
        try state.commit(state.prepare(request("down", x: 0.1)))
        XCTAssertThrowsError(try state.commit(pendingMove))
        XCTAssertEqual(state.owner, "finger")
        XCTAssertEqual(state.point, CGPoint(x: 0.1, y: 0.5))
        XCTAssertFalse(state.hasMoved)
    }

    func testHumanDisplayCancellationCannotClearAIContactOwnership() throws {
        var state = TouchDeliveryState()
        let down = Request(id: 1, command: "touch", phase: "down", x: 0.5, y: 0.5, pointer: "ai")
        try state.commit(state.prepare(down))
        state.invalidateHuman()
        XCTAssertEqual(state.owner, "ai")
        XCTAssertThrowsError(try state.prepare(request("down")))
    }

}
