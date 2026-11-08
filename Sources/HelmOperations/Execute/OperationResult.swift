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
    /// Identity, kind and token observed together after completion (F-059/B-041).
    public let destinationEvidence: FileMutationPrecondition?
    public let destinationKind: FileEntryKind?
    public let requiresReconciliation: Bool
    public init(step: PlannedStep, destination: URL?, result: Result<ChangeToken?, OperationError>, requiresReconciliation: Bool? = nil, destinationKind: FileEntryKind? = nil, destinationEvidence: FileMutationPrecondition? = nil) {
        self.destinationEvidence = destinationEvidence
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
/// One item that couldn't be done, offered to the person before the batch goes on (P-139).
public struct StepFailure: Sendable, Equatable {
    /// The item's name, as shown in the prompt.
    public let name: String
    public let error: OperationError
    /// Trying again is offered only when nothing was half done, so a retry can't trip over a partial copy.
    public let canRetry: Bool
    /// Items still to do after this one. With none, Skip and Stop end the same way.
    public let remaining: Int
    public init(name: String, error: OperationError, canRetry: Bool, remaining: Int) {
        self.name = name; self.error = error; self.canRetry = canRetry; self.remaining = remaining
    }
}

/// What the person chose for a failed item, as in Finder's Skip and Stop prompt.
public enum FailureDecision: Sendable, Equatable {
    /// Leave this item and go on with the rest.
    case skip
    /// Leave this item and every later one that fails, without asking again.
    case skipAll
    /// Try the same item again.
    case retry
    /// Stop here. Items not yet reached aren't attempted.
    case stop
}

public struct OperationProgress: Sendable, Equatable {
    public let id: OperationID
    public let itemsDone: Int
    public let itemsTotal: Int
    public let currentName: String?
    public init(id: OperationID, itemsDone: Int, itemsTotal: Int, currentName: String?) {
        self.id = id; self.itemsDone = itemsDone; self.itemsTotal = itemsTotal; self.currentName = currentName
    }
}
