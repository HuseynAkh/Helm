// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// App-retainable journal entry replaces per-tab UndoManager targets (F-059/B-100/B-105).
public struct JournalEntry: Sendable, Identifiable {
    public let id: OperationID
    public let plan: OperationPlan
    public let result: OperationResult?
    public init(id: OperationID, plan: OperationPlan, result: OperationResult? = nil) {
        self.id = id; self.plan = plan; self.result = result
    }
}
/// In-memory begin/step/complete storage; persistence belongs to another lane (B-038/B-105).
public actor OperationJournal {
    private var entries: [OperationID: JournalEntry] = [:]
    private var partial: [OperationID: [ItemOutcome]] = [:]
    private var recordedSteps: [OperationID: Set<StepID>] = [:]
    private var order: [OperationID] = []
    public init() {}
    public func begin(_ plan: OperationPlan) -> OperationID {
        let id = OperationID(); entries[id] = JournalEntry(id: id, plan: plan); partial[id] = []; order.append(id); return id
    }
    public func record(_ outcome: ItemOutcome, for id: OperationID) {
        guard let entry = entries[id], entry.result == nil else { return }
        guard recordedSteps[id, default: []].insert(outcome.step.id).inserted else { return }
        partial[id, default: []].append(outcome)
    }
    @discardableResult public func complete(_ result: OperationResult) -> Bool {
        guard let entry = entries[result.id], entry.result == nil else { return false }
        entries[result.id] = JournalEntry(id: result.id, plan: entry.plan, result: result)
        partial[result.id] = result.outcomes
        recordedSteps[result.id] = nil
        return true
    }
    public func entry(_ id: OperationID) -> JournalEntry? { entries[id] }
    public func outcomes(for id: OperationID) -> [ItemOutcome] { partial[id] ?? [] }
    public func allEntries() -> [JournalEntry] { order.compactMap { entries[$0] } }
}
/// Portable exact-origin store supports F-053 Put Back tests without persistence dependencies.
public actor InMemoryTrashOrigins: TrashOriginRecording {
    private var origins: [URL: URL] = [:]
    public init() {}
    public func record(_ items: [TrashedItem]) { for item in items { origins[item.trashedURL] = item.originalURL } }
    public func originalURL(forTrashed url: URL) -> URL? { origins[url] }
}
