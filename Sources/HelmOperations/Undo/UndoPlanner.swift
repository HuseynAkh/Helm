// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Reverses successful primitives in reverse order; undo never permanently deletes (F-059/B-041/B-042).
public enum UndoPlanner {
    public static func inverse(of entry: JournalEntry, recordedOrigins: [URL: URL]) -> OperationPlan {
        guard let result = entry.result else { return OperationPlan(command: .recovery, steps: [], issues: [.stopped]) }
        // An attempted failed mutation can be partially complete. Require reconciliation before undo.
        if result.outcomes.contains(where: \.requiresReconciliation) {
            return OperationPlan(command: .recovery, steps: [], issues: [.stopped])
        }
        // Tracked by path, so a step's source matches the earlier step that produced it however each URL is spelled.
        struct Produced { let url: URL; let token: ChangeToken; let evidence: FileMutationPrecondition?; let kind: FileEntryKind? }
        var produced: [String: Produced] = [:]
        for outcome in result.outcomes where outcome.succeeded && outcome.step.kind != .verifyCopy {
            if outcome.step.kind == .move || outcome.step.kind == .trash, let source = outcome.step.source {
                produced[source.evidenceKey] = nil
            }
            if let destination = outcome.destination, case .success(let token) = outcome.result {
                guard let token else { return OperationPlan(command: .recovery, steps: [], issues: [.stopped]) }
                produced[destination.evidenceKey] = Produced(url: destination, token: token,
                                                             evidence: outcome.destinationEvidence, kind: outcome.destinationKind)
            }
        }
        var expectedEvidence: [URL: FileMutationPrecondition] = [:]
        var expectedKinds: [URL: FileEntryKind] = [:]
        var expectedTokens: [URL: ChangeToken] = [:]
        for value in produced.values {
            expectedEvidence[value.url] = value.evidence
            expectedTokens[value.url] = value.token
            expectedKinds[value.url] = value.kind
        }
        var steps: [PlannedStep] = []
        for outcome in result.outcomes.reversed() where outcome.succeeded {
            let step = outcome.step
            if step.kind == .verifyCopy { continue }
            guard let destination = outcome.destination else {
                return OperationPlan(command: .recovery, steps: [], issues: [.stopped])
            }
            switch step.kind {
            case .copy, .createDirectory, .createFile, .createAlias, .createSymbolicLink:
                steps.append(PlannedStep(kind: .trash, source: destination))
            case .move:
                guard let source = step.source else { return OperationPlan(command: .recovery, steps: [], issues: [.stopped]) }
                steps.append(PlannedStep(kind: .move, source: destination, destination: source))
            case .trash:
                // Compared by path: a folder's URL may or may not end in a slash.
                guard let original = recordedOrigins[destination]
                        ?? recordedOrigins.first(where: { $0.key.evidenceKey == destination.evidenceKey })?.value,
                      original.evidenceKey == step.source?.evidenceKey else {
                    return OperationPlan(command: .recovery, steps: [], issues: [.stopped])
                }
                steps.append(PlannedStep(kind: .move, source: destination, destination: original))
            case .verifyCopy: break
            }
        }
        return OperationPlan(command: .recovery, steps: steps, context: entry.plan.context, expectedTokens: expectedTokens,
                             undoVerification: .sameObject, expectedKinds: expectedKinds, expectedEvidence: expectedEvidence)
    }
    public static func inverse(of entry: JournalEntry, origins: any TrashOriginRecording) async -> OperationPlan {
        var recorded: [URL: URL] = [:]
        for outcome in entry.result?.outcomes ?? [] where outcome.step.kind == .trash && outcome.succeeded {
            if let url = outcome.destination { recorded[url] = await origins.originalURL(forTrashed: url) }
        }
        return inverse(of: entry, recordedOrigins: recorded)
    }
}
