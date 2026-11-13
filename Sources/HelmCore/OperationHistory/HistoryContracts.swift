// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Single-use history reservation, independent of executor journal IDs (F-059/B-043).
public struct HistoryRequestID: Hashable, Sendable {
    public let rawValue: UUID
    public init(rawValue: UUID = UUID()) { self.rawValue = rawValue }
}

/// Several operations that the person undoes as one, such as the commands of one applied plan.
/// Edit shows "Undo " and the name, so the name reads as one change: "Organize “Downloads”".
public struct HistoryGroup: Hashable, Sendable {
    public let id: UUID
    public let name: String
    public init(id: UUID = UUID(), name: String) { self.id = id; self.name = name }
}

/// Named original user operation; inverse attempts never create these entries (F-059).
public struct HistoryEntry: Equatable, Sendable {
    public let operationID: OperationID
    public let name: String
    /// The group this operation ran under, or nil for an operation of its own. An entry in a group is named after it.
    public let group: HistoryGroup?
    public init(operationID: OperationID, name: String, group: HistoryGroup? = nil) {
        self.operationID = operationID; self.name = name; self.group = group
    }
}

/// Explicit completion distinguishes refusal from uncertain partial mutation (B-038/B-043).
public enum HistoryOutcome: Equatable, Sendable {
    case succeeded, noChange
    case failed(String), refused(String), unsupported(String)
    case partial(String), reconciliationRequired(String)
    /// Conservative inverse policy: a partial undo cannot safely be replayed.
    /// Forward completion latches only `reconciliationRequired`; a known prefix remains undoable.
    public var needsReconciliation: Bool {
        switch self {
        case .partial, .reconciliationRequired: return true
        default: return false
        }
    }
}

/// Named menu admission; a redo stack does not imply safe redo support (F-059/B-041).
public enum HistoryAvailability: Equatable, Sendable {
    case empty, busy, reconciliationRequired
    case available(String), unsupported(String)
}

/// Pending forward/undo request keeps the window busy across host suspension (B-100/B-105).
public enum HistoryReservation: Equatable, Sendable {
    case forward(HistoryRequestID, name: String)
    case undo(HistoryRequestID, HistoryEntry)
    public var request: HistoryRequestID {
        switch self {
        case .forward(let request, _), .undo(let request, _): return request
        }
    }
}

/// Pure history inputs; hosts must route text editing before file undo (F-059/B-041).
public enum HistoryAction: Sendable {
    case beginForward(HistoryRequestID, name: String)
    /// As `beginForward` under the group's name, and the entry this forward makes carries the group. Once such an
    /// entry is undone it is gone: it never reaches the redo stack.
    case beginGroupedForward(HistoryRequestID, HistoryGroup)
    case startForward(HistoryRequestID, operation: OperationID)
    case abortForward(HistoryRequestID, failure: HistoryPreparationFailure)
    case finishForward(HistoryRequestID, operation: OperationID, outcome: HistoryOutcome)
    case beginUndo(HistoryRequestID)
    case startUndo(HistoryRequestID, operation: OperationID)
    case abortUndo(HistoryRequestID, failure: HistoryPreparationFailure)
    case complete(HistoryRequestID, outcome: HistoryOutcome)
    case beginRedo
    /// Redo re-runs the original command, freshly planned, without discarding older redo entries.
    case beginRedoForward(HistoryRequestID)
    /// Retire the blocked undo entry after the host presents journal evidence and gets user confirmation.
    case acknowledgeReconciliation
    /// A change the history can't undo just happened, such as a new archive. Undo and Redo mustn't reach back past it
    /// to older changes, so both stacks are let go. Journal evidence stays.
    case discardEntries
}

/// Intent only: the history reducer never performs file mutations (F-059/B-041).
public enum HistoryEffect: Equatable, Sendable {
    case performUndo(HistoryRequestID, OperationID)
}


/// Pre-execution failure preserves visible errors without inventing mutation evidence (F-059/B-043).
public enum HistoryPreparationFailure: Equatable, Sendable {
    case cancelled
    case failed(String)
    public var outcome: HistoryOutcome {
        switch self {
        case .cancelled: return .failed("Cancelled before execution")
        case .failed(let message): return .failed(message)
        }
    }
}
