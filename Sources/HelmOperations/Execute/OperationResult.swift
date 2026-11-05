// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Explicit outcomes preserve partial work and uncertain completion (B-038/B-107).
public enum OperationError: Error, Hashable, Sendable {
    case cancelled, notAttempted, invalidPlan, busy, verificationUnavailable, verificationFailed
    case conflict, timedOut, sourceChanged(URL), other(String)
}
/// A successful primitive records its actual paths, including Trash and temporary names (B-042).
public struct ItemOutcome: Sendable {
    public let step: PlannedStep
    public let destination: URL?
    public let result: Result<ChangeToken?, OperationError>
    /// No-follow kind observed after mutation; missing metadata cannot authorize automatic undo.
    public let destinationKind: FileEntryKind?
    public let requiresReconciliation: Bool
    public init(step: PlannedStep, destination: URL?, result: Result<ChangeToken?, OperationError>, requiresReconciliation: Bool? = nil, destinationKind: FileEntryKind? = nil) {
        self.destinationKind = destinationKind
        self.step = step; self.destination = destination; self.result = result
        if case .failure(let error) = result { self.requiresReconciliation = requiresReconciliation ?? (error != .notAttempted) }
        else { self.requiresReconciliation = false }
    }
    public var succeeded: Bool { if case .success = result { return true }; return false }
}
/// One operation result survives initiating tab closure (B-100/B-105).
public struct OperationResult: Sendable {
    public let id: OperationID
    public let command: Command
    public let outcomes: [ItemOutcome]
    public let error: OperationError?
    public var succeededCount: Int { outcomes.filter(\.succeeded).count }
    public var failedCount: Int { outcomes.filter { !$0.succeeded }.count }
    /// Only completed original cut sources may be removed from clipboard metadata (B-037).
    public var completedMoveSources: Set<URL> {
        completedMoveSources(visit: {})
    }
    func completedMoveSources(visit: () -> Void) -> Set<URL> {
        guard case .move(let sources, _) = command else { return [] }
        var completed: Set<URL> = []
        for outcome in outcomes {
            visit()
            if outcome.succeeded, outcome.step.kind == .move || outcome.step.kind == .trash,
               let source = outcome.step.source { completed.insert(source) }
        }
        var original: Set<URL> = []
        for source in sources { visit(); original.insert(source) }
        return completed.intersection(original)
    }

    public var wasCancelled: Bool { error == .cancelled }
    public var affectedDirectories: Set<URL> {
        Set(outcomes.flatMap { [$0.step.source, $0.destination].compactMap { $0?.deletingLastPathComponent() } })
    }
    public init(id: OperationID, command: Command, outcomes: [ItemOutcome], error: OperationError? = nil) {
        self.id = id; self.command = command; self.outcomes = outcomes; self.error = error
    }
}
/// Honest primitive-level progress for F-061; no invented byte estimates.
public struct OperationProgress: Sendable, Equatable {
    public let id: OperationID
    public let itemsDone: Int
    public let itemsTotal: Int
    public let currentName: String?
    public init(id: OperationID, itemsDone: Int, itemsTotal: Int, currentName: String?) {
        self.id = id; self.itemsDone = itemsDone; self.itemsTotal = itemsTotal; self.currentName = currentName
    }
}
