// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Reserved inverse intent; execution remains the host's responsibility (F-059/B-041).
public struct HistoryUndoRequest: Sendable {
    public let request: HistoryRequestID
    public let originalOperation: OperationID
    public let plan: OperationPlan
    public init(request: HistoryRequestID, originalOperation: OperationID, plan: OperationPlan) {
        self.request = request; self.originalOperation = originalOperation; self.plan = plan
    }
}

/// One instance per window, retained before an operation starts (F-059/B-100/B-105).
/// This value-only adapter does no I/O and never executes, relaxes or replays journal steps.
public actor WindowOperationHistory {
    private var state: OperationHistoryState = OperationHistoryState()
    private var entries: [OperationID: JournalEntry] = [:]
    private var seenOperations: Set<OperationID> = []
    private var forwardCommand: Command?
    private var inverse: HistoryUndoRequest?
    private var completedInverses: [JournalEntry] = []
    public init() {}
    public func snapshot() -> OperationHistoryState { state }
    /// Original evidence stays available to a future reconciliation host (B-038).
    public func entry(for operation: OperationID) -> JournalEntry? { entries[operation] }
    /// Inverse attempts are retained separately and never enter the user undo stack (B-043).
    public func inverseAttempts() -> [JournalEntry] { completedInverses }

    /// Reserve before the host starts a forward operation, including across tab changes.
    public func beginForward(_ command: Command) -> HistoryRequestID? {
        guard command != .recovery else { return nil }
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginForward(request, name: HistoryResultMapping.name(for: command)))
        guard state.pending?.request == request else { return nil }
        forwardCommand = command
        return request
    }

    /// Accept only the original command's completed journal entry, once.
    @discardableResult
    public func completeForward(request: HistoryRequestID, entry: JournalEntry) -> Bool {
        guard case .forward(request, _) = state.pending, let command = forwardCommand,
              entry.plan.command == command, let result = entry.result,
              result.id == entry.id, result.command == command,
              !seenOperations.contains(entry.id) else { return false }
        seenOperations.insert(entry.id)
        entries[entry.id] = entry
        OperationHistoryReducer.reduce(&state, .finishForward(request, operation: entry.id,
            outcome: HistoryResultMapping.outcome(result, plan: entry.plan)))
        forwardCommand = nil
        return true
    }

    /// Origins are supplied values. The existing UndoPlanner retains all ownership/leaf checks.
    public func beginUndo(recordedOrigins: [URL: URL] = [:]) -> HistoryUndoRequest? {
        let request = HistoryRequestID()
        let effects = OperationHistoryReducer.reduce(&state, .beginUndo(request))
        guard case .performUndo(request, let operation) = effects.first else { return nil }
        guard let entry = entries[operation] else {
            OperationHistoryReducer.reduce(&state, .complete(request, outcome: .refused("Missing journal entry")))
            return nil
        }
        let plan = UndoPlanner.inverse(of: entry, recordedOrigins: recordedOrigins)
        guard plan.isExecutable, !plan.steps.isEmpty else {
            OperationHistoryReducer.reduce(&state, .complete(request, outcome: .refused("Inverse planning refused")))
            return nil
        }
        let value = HistoryUndoRequest(request: request, originalOperation: operation, plan: plan)
        inverse = value
        return value
    }

    /// Completion cannot register the inverse as a user edit or consume another reservation.
    @discardableResult
    public func complete(request: HistoryRequestID, outcome: OperationResult) -> Bool {
        guard let pending = inverse, pending.request == request,
              state.pending?.request == request, outcome.command == pending.plan.command,
              !seenOperations.contains(outcome.id) else { return false }
        seenOperations.insert(outcome.id)
        completedInverses.append(JournalEntry(id: outcome.id, plan: pending.plan, result: outcome))
        OperationHistoryReducer.reduce(&state, .complete(request,
            outcome: HistoryResultMapping.outcome(outcome, plan: pending.plan)))
        inverse = nil
        return true
    }

    /// Explicitly unsupported: stale paths/steps are never used as redo authorization.
    public func beginRedo() -> HistoryAvailability {
        OperationHistoryReducer.reduce(&state, .beginRedo)
        return state.redoAvailability
    }
}
