import Foundation
import CoreGraphics

struct Request: Decodable, Sendable {
    let id: Int
    let command: String
    var phase: String?
    var x: Double?
    var y: Double?
    var pointer: String?
    var key: String?
    var text: String?
    var paste: Bool?
}

struct HelperFailure: Error, LocalizedError, Sendable {
    let code: String
    let message: String
    var errorDescription: String? { message }
    static func invalid(_ message: String) -> Self { .init(code: "INVALID_ARGUMENT", message: message) }
}

struct TouchOwnership {
    private(set) var owner: String?
    private(set) var point: CGPoint = .zero
    private(set) var hasMoved = false
    mutating func apply(_ request: Request) throws -> (String, CGPoint) {
        guard let pointer = request.pointer, ["finger", "ai"].contains(pointer),
              let phase = request.phase, ["down", "move", "up"].contains(phase),
              let x = request.x, let y = request.y,
              x.isFinite, y.isFinite, (0...1).contains(x), (0...1).contains(y) else {
            throw HelperFailure.invalid("touch requires phase, pointer and finite x/y in 0...1")
        }
        if let owner, owner != pointer {
            throw HelperFailure(code: "AI_LOCKED", message: "Touch is owned by \(owner)")
        }
        if phase != "down", owner == nil {
            throw HelperFailure.invalid("Touch \(phase) requires a preceding down")
        }
        let nextPoint = CGPoint(x: x, y: y)
        if phase == "down" || phase == "up" { hasMoved = false }
        else if nextPoint != point { hasMoved = true }
        point = nextPoint
        owner = phase == "up" ? nil : pointer
        return (phase, point)
    }
}

struct LineFramer {
    let limit: Int
    private var pending = Data()
    init(limit: Int = 32 * 1024 * 1024) { self.limit = limit }
    mutating func append(_ data: Data) throws -> [Data] {
        pending.append(data)
        var lines: [Data] = []
        while let end = pending.firstIndex(of: 10) {
            guard pending.distance(from: pending.startIndex, to: end) <= limit else {
                throw HelperFailure.invalid("JSON line exceeds limit")
            }
            var line = Data(pending[..<end])
            pending.removeSubrange(...end)
            if line.last == 13 { line.removeLast() }
            if !line.isEmpty { lines.append(line) }
        }
        guard pending.count <= limit else { throw HelperFailure.invalid("JSON line exceeds limit") }
        return lines
    }
}

struct MenuItem: Equatable, Sendable {
    let label: String
    let identifier: String?
    let role: String
    let frame: CGRect
    let isNativeMenu: Bool
}

struct PasteMenu {
    private(set) var candidate: MenuItem?
    private var stableSince: ContinuousClock.Instant?
    static let labels: Set<String> = ["Paste", "粘贴", "貼上", "ペースト", "붙여넣기", "Coller", "Einsetzen", "Pegar", "Incolla", "Colar", "Вставить"]

    mutating func observe(_ items: [MenuItem], baseline: [MenuItem], at now: ContinuousClock.Instant) -> MenuItem? {
        let nativeItems = items.filter { $0.isNativeMenu && Self.labels.contains($0.label) && $0.frame.width > 0 && $0.frame.height > 0 }
        guard nativeItems.count == 1 else { candidate = nil; stableSince = nil; return nil }
        let candidates = nativeItems.filter { item in
            !baseline.contains { previous in
                if let id = item.identifier, !id.isEmpty, let oldID = previous.identifier, !oldID.isEmpty { return id == oldID }
                return previous.label == item.label && previous.role == item.role && previous.frame == item.frame
            }
        }
        guard candidates.count == 1, let next = candidates.first else {
            candidate = nil; stableSince = nil; return nil
        }
        if candidate != next { candidate = next; stableSince = now }
        guard let stableSince, stableSince.duration(to: now) >= .seconds(1) else { return nil }
        return next
    }
}

/// An input ACK may resume after display cancellation; commit only current human input.
struct TouchDeliveryState {
    struct Pending {
        fileprivate let next: TouchOwnership
        fileprivate let human: Bool
        fileprivate let epoch: UInt64
        let phase: String
        let point: CGPoint
    }
    private var ownership = TouchOwnership()
    private var humanEpoch: UInt64 = 0
    var owner: String? { ownership.owner }
    var point: CGPoint { ownership.point }
    var hasMoved: Bool { ownership.hasMoved }

    func prepare(_ request: Request) throws -> Pending {
        var next = ownership
        let (phase, point) = try next.apply(request)
        return Pending(next: next, human: request.pointer == "finger", epoch: humanEpoch, phase: phase, point: point)
    }
    func validate(_ pending: Pending) throws {
        guard !pending.human || pending.epoch == humanEpoch else {
            throw HelperFailure(code: "CONNECTION_FAILED", message: "Touch display changed before delivery completed")
        }
    }
    mutating func commit(_ pending: Pending) throws {
        try validate(pending)
        ownership = pending.next
    }
    mutating func observeDisplayChange(from previous: UInt64?, to current: UInt64) -> Bool {
        // The framebuffer's first asynchronous report initializes the binding;
        // it must not cancel a touch currently fetching that initial geometry.
        guard let previous, previous != current else { return false }
        invalidateHuman()
        return true
    }
    mutating func invalidateHuman() {
        humanEpoch &+= 1
        if ownership.owner == "finger" { ownership = TouchOwnership() }
    }
}
