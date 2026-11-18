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
    private var execution: (id: OperationID, plan: OperationPlan)?
    private var inverse: HistoryUndoRequest?
    private var completedInverses: [JournalEntry] = []
    /// Permissions changes, which the host makes outside the executor, by the entry each one made.
    private var permissionChanges: [OperationID: PermissionChange] = [:]
    /// The reservation a permissions change, its Undo or its Redo holds, while the host makes it.
    private var permissionRequest: HistoryRequestID?
    public init() {}
    public func snapshot() -> OperationHistoryState { state }
    /// Original evidence stays available to a future reconciliation host (B-038).
    public func entry(for operation: OperationID) -> JournalEntry? { entries[operation] }
    /// Inverse attempts are retained separately and never enter the user undo stack (B-043).
    public func inverseAttempts() -> [JournalEntry] { completedInverses }

    /// Reserve before the host starts a forward operation, including across tab changes.
    /// Under a group the reservation and its entry take the group's name, and the entry carries the group, so the
    /// operations of one group are undone as one.
    public func beginForward(_ command: Command, group: HistoryGroup? = nil) -> HistoryRequestID? {
        guard command != .recovery else { return nil }
        let request = HistoryRequestID()
        if let group {
            OperationHistoryReducer.reduce(&state, .beginGroupedForward(request, group))
        } else {
            OperationHistoryReducer.reduce(&state, .beginForward(request, name: HistoryResultMapping.name(for: command)))
        }
        guard state.pending?.request == request else { return nil }
        forwardCommand = command
        return request
    }

    /// Bind from the executor admission callback, before any filesystem work (B-043/B-105).
    /// A rejected binding must prevent that execution from mutating.
    @discardableResult
    public func bindExecution(request: HistoryRequestID, operation: OperationID, plan: OperationPlan) -> Bool {
        guard state.pending?.request == request, execution == nil,
              !seenOperations.contains(operation) else { return false }
        if let command = forwardCommand {
            guard plan.command == command else { return false }
            OperationHistoryReducer.reduce(&state, .startForward(request, operation: operation))
            guard state.executingOperation == operation else { return false }
        } else {
            guard let inverse, inverse.request == request,
                  plan == inverse.plan else { return false }
            OperationHistoryReducer.reduce(&state, .startUndo(request, operation: operation))
            guard state.executingOperation == operation else { return false }
        }
        execution = (operation, plan)
        return true
    }

    /// Only reserved preparation can abort; cancellation after binding must await completion.
    @discardableResult
    public func abortForward(request: HistoryRequestID, failure: HistoryPreparationFailure) -> Bool {
        guard case .forward(request, _) = state.pending, execution == nil else { return false }
        OperationHistoryReducer.reduce(&state, .abortForward(request, failure: failure))
        forwardCommand = nil
        return true
    }

    /// Abort inverse preparation without consuming its original entry (F-059/B-043).
    /// Once binding wins, the retained execution must settle through complete instead.
    @discardableResult
    public func abortUndo(request: HistoryRequestID, failure: HistoryPreparationFailure) -> Bool {
        guard case .undo(request, _) = state.pending, inverse?.request == request,
              execution == nil else { return false }
        OperationHistoryReducer.reduce(&state, .abortUndo(request, failure: failure))
        inverse = nil
        return true
    }

    /// Accept only the original command's completed journal entry, once.
    @discardableResult
    public func completeForward(request: HistoryRequestID, entry: JournalEntry) -> Bool {
        guard case .forward(request, _) = state.pending, let command = forwardCommand,
              let execution, execution.id == entry.id,
              entry.plan.steps == execution.plan.steps,
              entry.plan.command == command, let result = entry.result,
              result.outcomes.map(\.step) == execution.plan.steps,
              result.id == entry.id, result.command == command,
              !seenOperations.contains(entry.id) else { return false }
        seenOperations.insert(entry.id)
        entries[entry.id] = JournalEntry(id: entry.id, plan: execution.plan, result: result)
        OperationHistoryReducer.reduce(&state, .finishForward(request, operation: entry.id,
            outcome: HistoryResultMapping.outcome(result, plan: entry.plan)))
        forwardCommand = nil
        self.execution = nil
        return true
    }

    /// Origins are supplied values. The existing UndoPlanner retains all ownership/leaf checks.
    public func beginUndo(recordedOrigins: [URL: URL]) -> HistoryUndoRequest? {
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
              let execution, execution.id == outcome.id,
              outcome.outcomes.map(\.step) == pending.plan.steps,
              !seenOperations.contains(outcome.id) else { return false }
        seenOperations.insert(outcome.id)
        completedInverses.append(JournalEntry(id: outcome.id, plan: pending.plan, result: outcome))
        OperationHistoryReducer.reduce(&state, .complete(request,
            outcome: HistoryResultMapping.outcome(outcome, plan: pending.plan)))
        inverse = nil
        self.execution = nil
        return true
    }

    /// Retire blocked undo authority only after explicit user confirmation (F-059/B-038/B-043).
    /// The host must first show original and inverse journal outcomes, including hidden stage/backup paths.
    /// This does not repair files or verify recovery; all journal evidence remains available.
    @discardableResult
    public func acknowledgeReconciliation() -> Bool {
        guard state.pending == nil, state.reconciliation != nil else { return false }
        OperationHistoryReducer.reduce(&state, .acknowledgeReconciliation)
        return true
    }

    /// Redo re-runs the original command, which the host plans afresh against the current disk,
    /// so stale paths and steps are never replayed (O1-1).
    public func beginRedoForward() -> (request: HistoryRequestID, command: Command)? {
        guard let entry = state.redoEntries.last, let command = entries[entry.operationID]?.plan.command else { return nil }
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginRedoForward(request))
        guard state.pending?.request == request else { return nil }
        forwardCommand = command
        return (request, command)
    }

    /// A change outside the history, such as a new archive, happened in this window: Undo mustn't reach back past it.
    /// Refused while an operation holds the history.
    @discardableResult
    public func discardEntries() -> Bool {
        guard state.pending == nil else { return false }
        OperationHistoryReducer.reduce(&state, .discardEntries)
        return true
    }

    /// Reports redo availability without performing it.
    public func beginRedo() -> HistoryAvailability {
        OperationHistoryReducer.reduce(&state, .beginRedo)
        return state.redoAvailability
    }

    // MARK: Permissions changes

    /// What Edit calls a permissions change: "Undo Change Permissions".
    public static let permissionChangeName = "Change Permissions"

    /// Reserves the history for a change to an item's permissions, as `beginForward` does for an operation, so nothing
    /// else in the window starts meanwhile. Nil while the history is busy or waits on a reconciliation.
    public func beginPermissionChange() -> HistoryRequestID? {
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginForward(request, name: Self.permissionChangeName))
        guard state.pending?.request == request else { return nil }
        forwardCommand = nil
        permissionRequest = request
        return request
    }

    /// Ends a reservation from `beginPermissionChange` or `beginPermissionRedo`. A change that was made becomes one
    /// entry, which Undo takes back. Nil means nothing changed, and the reservation goes with nothing recorded.
    @discardableResult
    public func finishPermissionChange(request: HistoryRequestID, change: PermissionChange?, failure: String = "Nothing changed") -> Bool {
        guard case .forward(request, _) = state.pending, permissionRequest == request, execution == nil else { return false }
        permissionRequest = nil
        guard let change, change.before != change.after else {
            OperationHistoryReducer.reduce(&state, .abortForward(request, failure: .failed(failure)))
            return true
        }
        let operation = OperationID()
        OperationHistoryReducer.reduce(&state, .startForward(request, operation: operation))
        OperationHistoryReducer.reduce(&state, .finishForward(request, operation: operation, outcome: .succeeded))
        seenOperations.insert(operation)
        permissionChanges[operation] = change
        return true
    }

    /// The permissions change Undo would take back next, when the latest entry is one.
    public func permissionChangeToUndo() -> PermissionChange? {
        state.undoEntries.last.flatMap { permissionChanges[$0.operationID] }
    }
    /// The permissions change Redo would make again next, when the latest undone entry is one.
    public func permissionChangeToRedo() -> PermissionChange? {
        state.redoEntries.last.flatMap { permissionChanges[$0.operationID] }
    }

    /// Reserves Undo for the latest entry when it's a permissions change, and hands back the change to take back.
    /// Nil when it isn't one, or the history is busy.
    public func beginPermissionUndo() -> (request: HistoryRequestID, change: PermissionChange)? {
        guard let top = state.undoEntries.last, let change = permissionChanges[top.operationID] else { return nil }
        let request = HistoryRequestID()
        let effects = OperationHistoryReducer.reduce(&state, .beginUndo(request))
        guard case .performUndo(request, top.operationID) = effects.first else { return nil }
        permissionRequest = request
        return (request, change)
    }

    /// Ends a reservation from `beginPermissionUndo`. Put back, the entry moves to Redo. Refused, with nothing
    /// changed, it stays where it was, as an operation whose Undo is refused does.
    @discardableResult
    public func finishPermissionUndo(request: HistoryRequestID, restored: Bool, failure: String = "Refused") -> Bool {
        guard case .undo(request, _) = state.pending, permissionRequest == request, execution == nil else { return false }
        permissionRequest = nil
        guard restored else {
            OperationHistoryReducer.reduce(&state, .complete(request, outcome: .refused(failure)))
            return true
        }
        let operation = OperationID()
        OperationHistoryReducer.reduce(&state, .startUndo(request, operation: operation))
        OperationHistoryReducer.reduce(&state, .complete(request, outcome: .succeeded))
        seenOperations.insert(operation)
        return true
    }

    /// Reserves Redo for the latest undone entry when it's a permissions change, and hands back the change to make
    /// again. The host makes it afresh and ends it with `finishPermissionChange`, so it becomes a new entry. As with
    /// an operation's Redo, the undone entry is let go as it starts.
    public func beginPermissionRedo() -> (request: HistoryRequestID, change: PermissionChange)? {
        guard let entry = state.redoEntries.last, let change = permissionChanges[entry.operationID] else { return nil }
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginRedoForward(request))
        guard state.pending?.request == request else { return nil }
        forwardCommand = nil
        permissionRequest = request
        return (request, change)
    }
}

/// A change to one item's permissions, which Properties makes and the window's history keeps, so Undo puts the mode
/// back and Redo makes it again. Each is made only while the item is still the one with `identity` and has the mode
/// the other left.
public struct PermissionChange: Equatable, Sendable {
    public let item: URL
    public let identity: FileObjectIdentity
    public let before: UInt16
    public let after: UInt16
    public init(item: URL, identity: FileObjectIdentity, before: UInt16, after: UInt16) {
        self.item = item; self.identity = identity; self.before = before; self.after = after
    }
}
