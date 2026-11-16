// Offline design prototype only. No DeviceActions, USB, UI input, or production imports.
// Run: swift Prototypes/IOSUSB/AXProbe/TreeExecutionPlanPrototype.swift
import Foundation

struct PlanNode: Equatable {
    // A local index is deliberately absent: selectors are re-resolved in every fresh tree.
    let identifier: String
    let role: String
    let label: String
    let value: String
    let actionable: Bool
}

struct PlanState {
    let device: String
    let session: String
    let snapshot: String
    let app: String
    let nodes: [PlanNode]
}

struct PlanSelector {
    let identifier: String?
    let role: String
    let label: String?
    let value: String?

    func matches(_ node: PlanNode) -> Bool {
        node.role == role
            && (identifier == nil || identifier == node.identifier)
            && (label == nil || label == node.label)
            && (value == nil || value == node.value)
    }

    var isSpecific: Bool {
        !role.isEmpty && (identifier?.isEmpty == false || label?.isEmpty == false)
    }
}

struct PlanGuard {
    let app: String
    // Includes task context such as the exact selected contact, not only the target button.
    let present: [PlanSelector]
    let absent: [PlanSelector]
}

struct GuardedStep {
    enum Action { case tap, fill(String) }
    let before: PlanGuard
    let target: PlanSelector
    let action: Action
    let after: PlanGuard
}

struct GuardedPlan {
    let device: String
    let session: String
    let basisSnapshot: String
    let steps: [GuardedStep]
}

enum PlanValidationError: Error, Equatable {
    case invalidPlan, wrongBasis, wrongDeviceOrSession, wrongApp
    case nonSpecificSelector, missingOrAmbiguousElement, nonActionable
    case guardFailed, refreshRequired, exhausted, uncertainAction
}

struct PlanCursor {
    let plan: GuardedPlan
    private(set) var completed = 0
    private var lastSnapshot: String
    private var preparedSnapshot: String?
    private var uncertain = false

    init(_ plan: GuardedPlan, observed: PlanState) throws {
        guard (1...3).contains(plan.steps.count) else { throw PlanValidationError.invalidPlan }
        guard !plan.device.isEmpty, !plan.session.isEmpty, !plan.basisSnapshot.isEmpty else {
            throw PlanValidationError.invalidPlan
        }
        for step in plan.steps {
            guard step.target.isSpecific else { throw PlanValidationError.nonSpecificSelector }
            for condition in [step.before, step.after] {
                guard !condition.app.isEmpty, !condition.present.isEmpty else { throw PlanValidationError.invalidPlan }
                guard (condition.present + condition.absent).allSatisfy(\.isSpecific) else {
                    throw PlanValidationError.nonSpecificSelector
                }
            }
            if case .fill(let text) = step.action, text.isEmpty { throw PlanValidationError.invalidPlan }
        }
        guard plan.device == observed.device, plan.session == observed.session else {
            throw PlanValidationError.wrongDeviceOrSession
        }
        guard plan.basisSnapshot == observed.snapshot else { throw PlanValidationError.wrongBasis }
        self.plan = plan
        lastSnapshot = observed.snapshot
    }

    // The production executor MUST call this inside its existing per-device action lock,
    // using a tree read immediately before input. No cached coordinates may be returned.
    mutating func prepare(fresh state: PlanState) throws -> PlanNode {
        guard !uncertain else { throw PlanValidationError.uncertainAction }
        guard completed < plan.steps.count else { throw PlanValidationError.exhausted }
        guard preparedSnapshot == nil else { throw PlanValidationError.refreshRequired }
        try checkIdentity(state)
        guard state.snapshot != lastSnapshot else { throw PlanValidationError.refreshRequired }
        let step = plan.steps[completed]
        try check(step.before, state)
        let target = try unique(step.target, state)
        guard target.actionable else { throw PlanValidationError.nonActionable }
        if case .fill(let text) = step.action, text.isEmpty { throw PlanValidationError.invalidPlan }
        preparedSnapshot = state.snapshot
        return target
    }

    // Call only after input has acknowledged success, using a NEW tree. Success of HID
    // transport alone does not prove a postcondition. A timeout must stop this cursor.
    mutating func confirm(fresh state: PlanState) throws {
        guard !uncertain else { throw PlanValidationError.uncertainAction }
        guard let preparedSnapshot else { throw PlanValidationError.refreshRequired }
        try checkIdentity(state)
        guard state.snapshot != preparedSnapshot, state.snapshot != lastSnapshot else {
            throw PlanValidationError.refreshRequired
        }
        try check(plan.steps[completed].after, state)
        completed += 1
        lastSnapshot = state.snapshot
        self.preparedSnapshot = nil
    }

    mutating func markUncertain() { uncertain = true }

    private func checkIdentity(_ state: PlanState) throws {
        guard state.device == plan.device, state.session == plan.session else {
            throw PlanValidationError.wrongDeviceOrSession
        }
    }

    private func unique(_ selector: PlanSelector, _ state: PlanState) throws -> PlanNode {
        guard selector.isSpecific else { throw PlanValidationError.nonSpecificSelector }
        let found = state.nodes.filter(selector.matches)
        guard found.count == 1 else { throw PlanValidationError.missingOrAmbiguousElement }
        return found[0]
    }

    private func check(_ condition: PlanGuard, _ state: PlanState) throws {
        guard condition.app == state.app else { throw PlanValidationError.wrongApp }
        guard !condition.present.isEmpty else { throw PlanValidationError.invalidPlan }
        for selector in condition.present { _ = try unique(selector, state) }
        for selector in condition.absent {
            guard selector.isSpecific else { throw PlanValidationError.nonSpecificSelector }
            guard !state.nodes.contains(where: selector.matches) else { throw PlanValidationError.guardFailed }
        }
    }
}

// Standalone fixtures. They never connect to a device or execute the modeled action.
let search = PlanNode(identifier: "search", role: "textField", label: "搜索", value: "", actionable: true)
let result = PlanNode(identifier: "contact-xue", role: "button", label: "雪", value: "", actionable: true)
let searchSelector = PlanSelector(identifier: "search", role: "textField", label: "搜索", value: nil)
let resultSelector = PlanSelector(identifier: "contact-xue", role: "button", label: "雪", value: nil)
let before = PlanGuard(app: "fixture.app", present: [searchSelector], absent: [])
let after = PlanGuard(app: "fixture.app", present: [resultSelector], absent: [])
let step = GuardedStep(before: before, target: searchSelector, action: .fill("雪"), after: after)
let plan = GuardedPlan(device: "fixture-device", session: "session-1", basisSnapshot: "s0", steps: [step])
func state(_ snapshot: String, nodes: [PlanNode] = [search], app: String = "fixture.app", session: String = "session-1") -> PlanState {
    PlanState(device: "fixture-device", session: session, snapshot: snapshot, app: app, nodes: nodes)
}
func expectError(_ expected: PlanValidationError, _ body: () throws -> Void) {
    do { try body(); fatalError("Expected \(expected)") }
    catch { precondition(error as? PlanValidationError == expected, "Unexpected \(error)") }
}
var valid = try PlanCursor(plan, observed: state("s0"))
let prepared = try valid.prepare(fresh: state("s1"))
precondition(prepared == search)
try valid.confirm(fresh: state("s2", nodes: [result]))
precondition(valid.completed == 1)
expectError(.exhausted) { _ = try valid.prepare(fresh: state("s3")) }
expectError(.wrongBasis) { _ = try PlanCursor(plan, observed: state("other")) }
var stale = try PlanCursor(plan, observed: state("s0"))
expectError(.refreshRequired) { _ = try stale.prepare(fresh: state("s0")) }
expectError(.wrongDeviceOrSession) { _ = try stale.prepare(fresh: state("s1", session: "session-2")) }
expectError(.wrongApp) { _ = try stale.prepare(fresh: state("s1", app: "another.app")) }
expectError(.missingOrAmbiguousElement) { _ = try stale.prepare(fresh: state("s1", nodes: [search, search])) }
expectError(.missingOrAmbiguousElement) { _ = try stale.prepare(fresh: state("s1", nodes: [])) }
let relabeled = PlanNode(identifier: "search", role: "textField", label: "密码", value: "", actionable: true)
expectError(.missingOrAmbiguousElement) { _ = try stale.prepare(fresh: state("s1", nodes: [relabeled])) }
let disabled = PlanNode(identifier: "search", role: "textField", label: "搜索", value: "", actionable: false)
expectError(.nonActionable) { _ = try stale.prepare(fresh: state("s1", nodes: [disabled])) }
var unconfirmed = try PlanCursor(plan, observed: state("s0"))
_ = try unconfirmed.prepare(fresh: state("s1"))
expectError(.refreshRequired) { _ = try unconfirmed.prepare(fresh: state("s2")) }
expectError(.refreshRequired) { try unconfirmed.confirm(fresh: state("s1", nodes: [result])) }
expectError(.missingOrAmbiguousElement) { try unconfirmed.confirm(fresh: state("s2", nodes: [search])) }
precondition(unconfirmed.completed == 0)
var uncertain = try PlanCursor(plan, observed: state("s0"))
_ = try uncertain.prepare(fresh: state("s1"))
uncertain.markUncertain()
expectError(.uncertainAction) { try uncertain.confirm(fresh: state("s2", nodes: [result])) }
expectError(.uncertainAction) { _ = try uncertain.prepare(fresh: state("s3")) }
print("PASS: offline guarded-plan fixtures; no device input executed")
