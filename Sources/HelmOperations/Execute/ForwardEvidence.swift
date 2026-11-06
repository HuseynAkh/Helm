// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
import HelmFileSystem

extension URL {
    /// One spelling per item, whether or not it exists yet and whether or not a folder's URL ends in a slash.
    var evidenceKey: String { PathSpelling.standardPath(self) }
}

/// Forward metadata guards preserve directory Move/Trash (F-053/F-059) without weakening undo (B-041).
/// Provider identities accompany metadata; complete descendant/content proof is still unavailable.
struct ForwardEvidence {
    private enum Observation {
        case missing
        case failed(FileSystemError)
        case observed(ChangeToken, FileEntryKind, FileObjectIdentity?)
    }
    private var observations: [String: Observation] = [:]
    /// Undo holds only the object's identity to its recording; its contents may have changed since.
    private var identityOnly: Bool = false

    static func capture(_ plan: OperationPlan, fileSystem: any FileSystem) async -> ForwardEvidence {
        var evidence = ForwardEvidence()
        evidence.identityOnly = plan.undoVerification == .sameObject
        if plan.undoVerification != .none {
            for (url, value) in plan.expectedEvidence {
                evidence.observations[url.evidenceKey] = .observed(value.changeToken, value.kind, value.identity)
            }
            // Inverses may only use journal ownership, never a fresh pathname observation.
            return evidence
        }
        for (url, entry) in plan.context.existingEntries where plan.undoVerification == .none {
            evidence.observations[url.evidenceKey] = .observed(entry.changeToken, entry.kind, entry.objectIdentity)
        }
        for entry in plan.context.sourceManifest where plan.undoVerification == .none {
            evidence.observations[entry.source.evidenceKey] = .observed(entry.changeToken, entry.kind, entry.objectIdentity)
        }
        // Legacy/manual plans may lack planning metadata. Snapshot their original mutation sources
        // before progress callbacks, but never adopt a future stage/backup by its pathname.
        guard plan.context.sourceManifest.isEmpty, plan.context.existingEntries.isEmpty else { return evidence }
        var produced: Set<String> = []
        for step in plan.steps {
            if let source = step.source, !produced.contains(source.evidenceKey), evidence.observations[source.evidenceKey] == nil,
               step.kind == .copy || step.kind == .move || step.kind == .trash {
                do { evidence.record(source, entry: try await fileSystem.entry(at: source)) }
                catch { evidence.observations[source.evidenceKey] = .failed(FileSystemError.mapping(error)) }
            }
            if step.kind != .verifyCopy, let destination = step.destination { produced.insert(destination.evidenceKey) }
        }
        return evidence
    }

    func validate(_ url: URL?, fileSystem: any FileSystem) async throws {
        guard let url else { return }
        guard let observation = observations[url.evidenceKey] else { throw OperationError.verificationUnavailable }
        switch observation {
        case .missing: throw OperationError.verificationUnavailable
        case .failed(let error): throw error
        case .observed(let token, let kind, let identity):
            let current = try await fileSystem.entry(at: url)
            if identityOnly {
                guard current.kind == kind, identity != nil, current.objectIdentity == identity else {
                    throw OperationError.sourceChanged(url)
                }
                return
            }
            guard current.kind == kind, current.changeToken == token,
                  identity == nil || current.objectIdentity == identity else { throw OperationError.sourceChanged(url) }
        }
    }

    /// The evidence to mutate under. An identity-only plan re-reads metadata, since the recorded token may be stale.
    func precondition(for source: URL, fileSystem: any FileSystem) async throws -> FileMutationPrecondition {
        guard identityOnly else { return try precondition(for: source) }
        let recorded = try precondition(for: source)
        let current = try await fileSystem.entry(at: source)
        guard current.objectIdentity == recorded.identity, current.kind == recorded.kind else {
            throw OperationError.sourceChanged(source)
        }
        return FileMutationPrecondition(identity: recorded.identity, changeToken: current.changeToken, kind: current.kind)
    }

    func precondition(for source: URL) throws -> FileMutationPrecondition {
        guard case .observed(let token, let kind, let identity) = observations[source.evidenceKey], let identity else {
            throw OperationError.verificationUnavailable
        }
        return FileMutationPrecondition(identity: identity, changeToken: token, kind: kind)
    }

    func isMissing(_ url: URL?) -> Bool {
        guard let url, let observation = observations[url.evidenceKey] else { return false }
        if case .missing = observation { return true }
        return false
    }

    mutating func record(_ url: URL, entry: FileEntry?) {
        if let entry { observations[url.evidenceKey] = .observed(entry.changeToken, entry.kind, entry.objectIdentity) }
        else { observations[url.evidenceKey] = .missing }
    }

    mutating func completed(_ step: PlannedStep, destination: URL?, entry: FileEntry?) {
        // Verification does not establish new ownership: retain the copy's original evidence.
        guard step.kind != .verifyCopy else { return }
        if step.kind == .move || step.kind == .trash, let source = step.source {
            observations[source.evidenceKey] = .missing
        }
        if let destination { record(destination, entry: entry) }
    }
}
