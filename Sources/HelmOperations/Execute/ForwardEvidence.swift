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
    private var observations: [URL: Observation] = [:]

    static func capture(_ plan: OperationPlan, fileSystem: any FileSystem) async -> ForwardEvidence {
        var evidence = ForwardEvidence()
        for (url, entry) in plan.context.existingEntries where plan.undoVerification == .none {
            evidence.observations[url] = .observed(entry.changeToken, entry.kind, entry.objectIdentity)
        }
        for entry in plan.context.sourceManifest where plan.undoVerification == .none {
            evidence.observations[entry.source] = .observed(entry.changeToken, entry.kind, entry.objectIdentity)
        }
        // Legacy/manual plans may lack planning metadata. Snapshot their original mutation sources
        // before progress callbacks, but never adopt a future stage/backup by its pathname.
        var produced: Set<URL> = []
        for step in plan.steps {
            if let source = step.source, !produced.contains(source), evidence.observations[source] == nil,
               step.kind == .copy || step.kind == .move || step.kind == .trash {
                do { evidence.record(source, entry: try await fileSystem.entry(at: source)) }
                catch { evidence.observations[source] = .failed(FileSystemError.mapping(error)) }
            }
            if step.kind != .verifyCopy, let destination = step.destination { produced.insert(destination) }
        }
        return evidence
    }

    func validate(_ url: URL?, fileSystem: any FileSystem) async throws {
        guard let url, let observation = observations[url] else { return }
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
        guard case .observed(let token, let kind, let identity) = observations[source], let identity else {
            throw OperationError.verificationUnavailable
        }
        return FileMutationPrecondition(identity: identity, changeToken: token, kind: kind)
    }

    func isMissing(_ url: URL?) -> Bool {
        guard let url, let observation = observations[url] else { return false }
        if case .missing = observation { return true }
        return false
    }

    mutating func record(_ url: URL, entry: FileEntry?) {
        if let entry { observations[url] = .observed(entry.changeToken, entry.kind, entry.objectIdentity) }
        else { observations[url] = .missing }
    }

    mutating func completed(_ step: PlannedStep, destination: URL?, entry: FileEntry?) {
        // Verification does not establish new ownership: retain the copy's original evidence.
        guard step.kind != .verifyCopy else { return }
        if step.kind == .move || step.kind == .trash, let source = step.source {
            observations[source] = .missing
        }
        if let destination { record(destination, entry: entry) }
    }
}
