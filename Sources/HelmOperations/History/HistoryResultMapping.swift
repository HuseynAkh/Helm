// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Maps journal evidence without swallowing failure or partial work (F-059/B-038/B-043).
public enum HistoryResultMapping {
    public static func outcome(_ result: OperationResult, plan: OperationPlan) -> HistoryOutcome {
        let message: String = String(describing: result.error ?? .other("Incomplete operation"))
        if result.outcomes.contains(where: \.requiresReconciliation) {
            return .reconciliationRequired(message)
        }
        let mutated: Bool = result.outcomes.contains { $0.succeeded && $0.step.kind != .verifyCopy }
        let complete: Bool = result.error == nil && result.outcomes.allSatisfy(\.succeeded)
            && result.outcomes.map(\.step) == plan.steps
        if complete { return mutated ? .succeeded : .noChange }
        if mutated { return .partial(message) }
        let errors: [OperationError] = result.outcomes.compactMap {
            if case .failure(let error) = $0.result { return error }; return nil
        } + (result.error.map { [$0] } ?? [])
        if errors.contains(.verificationUnavailable) || errors.contains(.verificationFailed) || errors.contains(.invalidPlan) {
            return .refused(message)
        }
        return .failed(message)
    }

    public static func name(for command: Command) -> String {
        switch command {
        case .copy: return "Copy"
        case .move: return "Move"
        case .duplicate: return "Duplicate"
        case .trash: return "Move to Trash"
        case .rename, .batchRename: return "Rename"
        case .createFolder: return "New Folder"
        case .createFile: return "New File"
        case .link(_, _, let alias): return alias ? "Make Alias" : "Make Symbolic Link"
        case .recovery: return "Recovery"
        }
    }
}
