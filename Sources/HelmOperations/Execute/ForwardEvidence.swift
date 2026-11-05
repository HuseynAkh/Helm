// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
import HelmFileSystem

/// Forward metadata guards preserve directory Move/Trash (F-053/F-059) without weakening undo (B-041).
/// These observations detect kind/token changes; they are not persistent object identity or content hashes.
struct ForwardEvidence {
    private enum Observation {
        case missing
        case observed(ChangeToken, FileEntryKind)
    }
    private var observations: [URL: Observation] = [:]

    static func capture(_ plan: OperationPlan, fileSystem: any FileSystem) async -> ForwardEvidence {
        var evidence = ForwardEvidence()
        guard plan.undoVerification == .none else { return evidence }
        for (url, entry) in plan.context.existingEntries {
            evidence.observations[url] = .observed(entry.changeToken, entry.kind)
        }
        for entry in plan.context.sourceManifest {
            evidence.observations[entry.source] = .observed(entry.changeToken, entry.kind)
        }
        // Legacy/manual plans may lack planning metadata. Snapshot their original mutation sources
        // before progress callbacks, but never adopt a future stage/backup by its pathname.
        var produced: Set<URL> = []
        for step in plan.steps {
            if let source = step.source, !produced.contains(source), evidence.observations[source] == nil,
               step.kind == .move || step.kind == .trash {
                evidence.record(source, entry: try? await fileSystem.entry(at: source))
            }
            if step.kind != .verifyCopy, let destination = step.destination { produced.insert(destination) }
        }
        return evidence
    }

    func validate(_ url: URL?, fileSystem: any FileSystem) async throws {
        guard let url, let observation = observations[url] else { return }
        switch observation {
        case .missing: throw OperationError.verificationUnavailable
        case .observed(let token, let kind):
            let current = try await fileSystem.entry(at: url)
            guard current.kind == kind, current.changeToken == token else { throw OperationError.sourceChanged(url) }
        }
    }

    func isMissing(_ url: URL?) -> Bool {
        guard let url, let observation = observations[url] else { return false }
        if case .missing = observation { return true }
        return false
    }

    mutating func record(_ url: URL, entry: FileEntry?) {
        if let entry { observations[url] = .observed(entry.changeToken, entry.kind) }
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
