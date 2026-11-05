// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
import HelmFileSystem

/// Forward metadata guards preserve directory Move/Trash (F-053/F-059) without weakening undo (B-041).
/// Provider identities accompany metadata; complete descendant/content proof is still unavailable.
struct ForwardEvidence {
    private enum Observation {
        case missing
        case failed(FileSystemError)
        case observed(ChangeToken, FileEntryKind, FileObjectIdentity?)
    }
    private var observations: [String: Observation] = [:]

    static func capture(_ plan: OperationPlan, fileSystem: any FileSystem) async -> ForwardEvidence {
        var evidence = ForwardEvidence()
        if plan.undoVerification != .none {
            for (url, value) in plan.expectedEvidence {
                evidence.observations[url.path] = .observed(value.changeToken, value.kind, value.identity)
            }
            // Inverses may only use journal ownership, never a fresh pathname observation.
            return evidence
        }
        for (url, entry) in plan.context.existingEntries where plan.undoVerification == .none {
            evidence.observations[url.path] = .observed(entry.changeToken, entry.kind, entry.objectIdentity)
        }
        for entry in plan.context.sourceManifest where plan.undoVerification == .none {
            evidence.observations[entry.source.path] = .observed(entry.changeToken, entry.kind, entry.objectIdentity)
        }
        // Legacy/manual plans may lack planning metadata. Snapshot their original mutation sources
        // before progress callbacks, but never adopt a future stage/backup by its pathname.
        guard plan.context.sourceManifest.isEmpty, plan.context.existingEntries.isEmpty else { return evidence }
        var produced: Set<String> = []
        for step in plan.steps {
            if let source = step.source, !produced.contains(source.path), evidence.observations[source.path] == nil,
               step.kind == .copy || step.kind == .move || step.kind == .trash {
                do { evidence.record(source, entry: try await fileSystem.entry(at: source)) }
                catch { evidence.observations[source.path] = .failed(FileSystemError.mapping(error)) }
            }
            if step.kind != .verifyCopy, let destination = step.destination { produced.insert(destination.path) }
        }
        return evidence
    }

    func validate(_ url: URL?, fileSystem: any FileSystem) async throws {
        guard let url else { return }
        guard let observation = observations[url.path] else { throw OperationError.verificationUnavailable }
        switch observation {
        case .missing: throw OperationError.verificationUnavailable
        case .failed(let error): throw error
        case .observed(let token, let kind, let identity):
            let current = try await fileSystem.entry(at: url)
            guard current.kind == kind, current.changeToken == token,
                  identity == nil || current.objectIdentity == identity else { throw OperationError.sourceChanged(url) }
        }
    }

    func precondition(for source: URL) throws -> FileMutationPrecondition {
        guard case .observed(let token, let kind, let identity) = observations[source.path], let identity else {
            throw OperationError.verificationUnavailable
        }
        return FileMutationPrecondition(identity: identity, changeToken: token, kind: kind)
    }

    func isMissing(_ url: URL?) -> Bool {
        guard let url, let observation = observations[url.path] else { return false }
        if case .missing = observation { return true }
        return false
    }

    mutating func record(_ url: URL, entry: FileEntry?) {
        if let entry { observations[url.path] = .observed(entry.changeToken, entry.kind, entry.objectIdentity) }
        else { observations[url.path] = .missing }
    }

    mutating func completed(_ step: PlannedStep, destination: URL?, entry: FileEntry?) {
        // Verification does not establish new ownership: retain the copy's original evidence.
        guard step.kind != .verifyCopy else { return }
        if step.kind == .move || step.kind == .trash, let source = step.source {
            observations[source.path] = .missing
        }
        if let destination { record(destination, entry: entry) }
    }
}
