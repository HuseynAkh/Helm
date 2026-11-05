// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Window-owned named stacks survive tab closure (F-059/B-100/B-105).
/// Uncertain forward work and partial undo block history until explicitly acknowledged.
public struct OperationHistoryState: Sendable {
    public internal(set) var undoEntries: [HistoryEntry] = []
    public internal(set) var redoEntries: [HistoryEntry] = []
    public internal(set) var pending: HistoryReservation?
    public internal(set) var lastOutcome: HistoryOutcome?
    public internal(set) var reconciliation: HistoryOutcome?
    public internal(set) var executingOperation: OperationID?
    internal var usedRequests: Set<HistoryRequestID> = []
    internal var recordedOperations: Set<OperationID> = []
    public init() {}
    public var undoAvailability: HistoryAvailability {
        if pending != nil { return .busy }
        if reconciliation != nil { return .reconciliationRequired }
        guard let entry = undoEntries.last else { return .empty }
        return .available(entry.name)
    }
    public var redoAvailability: HistoryAvailability {
        if pending != nil { return .busy }
        if reconciliation != nil { return .reconciliationRequired }
        guard let entry = redoEntries.last else { return .empty }
        return .unsupported(entry.name)
    }
}

/// Serial value transitions preserve F-059 names and expose B-038/B-043 failures.
public enum OperationHistoryReducer {
    @discardableResult
    public static func reduce(_ state: inout OperationHistoryState, _ action: HistoryAction) -> [HistoryEffect] {
        switch action {
        case .beginForward(let request, let name):
            guard admit(&state, request) else { return [] }
            // Invalidate before the host can suspend or perform a new edit.
            state.redoEntries.removeAll()
            state.pending = .forward(request, name: name)
            state.lastOutcome = nil
        case .startForward(let request, let operation):
            guard case .forward(request, _) = state.pending, state.executingOperation == nil,
                  !state.recordedOperations.contains(operation) else { return [] }
            state.executingOperation = operation
        case .abortForward(let request, let failure):
            guard case .forward(request, _) = state.pending, state.executingOperation == nil else { return [] }
            state.pending = nil
            state.lastOutcome = failure.outcome
        case .finishForward(let request, let operation, let outcome):
            guard case .forward(request, let name) = state.pending,
                  state.executingOperation == operation,
                  !state.recordedOperations.contains(operation) else { return [] }
            state.executingOperation = nil
            state.recordedOperations.insert(operation)
            state.pending = nil
            state.lastOutcome = outcome
            if outcome == .succeeded || outcome.needsReconciliation {
                state.undoEntries.append(HistoryEntry(operationID: operation, name: name))
            }
            if case .reconciliationRequired = outcome { state.reconciliation = outcome }
        case .beginUndo(let request):
            guard let entry = state.undoEntries.last, admit(&state, request) else { return [] }
            state.pending = .undo(request, entry)
            state.lastOutcome = nil
            return [.performUndo(request, entry.operationID)]
        case .startUndo(let request, let operation):
            guard case .undo(request, _) = state.pending, state.executingOperation == nil,
                  !state.recordedOperations.contains(operation) else { return [] }
            state.executingOperation = operation
        case .abortUndo(let request, let failure):
            guard case .undo(request, _) = state.pending, state.executingOperation == nil else { return [] }
            state.pending = nil
            state.lastOutcome = failure.outcome
        case .complete(let request, let outcome):
            guard case .undo(request, let entry) = state.pending else { return [] }
            state.executingOperation = nil
            state.pending = nil
            state.lastOutcome = outcome
            if outcome == .succeeded {
                state.undoEntries.removeLast()
                state.redoEntries.append(entry)
            }
            if outcome.needsReconciliation { state.reconciliation = outcome }
        case .acknowledgeReconciliation:
            guard state.pending == nil, state.reconciliation != nil else { return [] }
            // Admission is blocked while latched, so only the top entry can be affected.
            // Retire it without creating redo authority or discarding journal evidence.
            if !state.undoEntries.isEmpty { state.undoEntries.removeLast() }
            state.reconciliation = nil
        case .beginRedo:
            guard state.pending == nil, state.reconciliation == nil, !state.redoEntries.isEmpty else { return [] }
            state.lastOutcome = .unsupported("Redo requires fresh intent validation and ownership evidence")
        }
        return []
    }
    private static func admit(_ state: inout OperationHistoryState, _ request: HistoryRequestID) -> Bool {
        guard state.pending == nil, state.reconciliation == nil,
              !state.usedRequests.contains(request) else { return false }
        state.usedRequests.insert(request)
        return true
    }
}
