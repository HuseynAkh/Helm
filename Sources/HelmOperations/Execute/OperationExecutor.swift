// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
import HelmFileSystem

/// Sequential, cancellable between primitives; partial mutations remain journaled (F-052/F-061/B-038).
public actor OperationExecutor {
    private let fileSystem: any FileSystem
    private let copier: any FileCopier
    private let verifier: any CopyVerifying
    private let origins: any TrashOriginRecording
    public let journal: OperationJournal
    private var running: Bool = false
    private var quarantined: Bool = false
    public init(fileSystem: any FileSystem, copier: (any FileCopier)? = nil,
                verifier: (any CopyVerifying)? = nil,
                origins: any TrashOriginRecording, journal: OperationJournal = OperationJournal()) {
        self.fileSystem = fileSystem; self.copier = copier ?? FoundationFileCopier(fileSystem: fileSystem)
        self.verifier = verifier ?? TreeCopyVerifier(fileSystem: fileSystem); self.origins = origins; self.journal = journal
    }
    /// Admission is awaited before filesystem access; false guarantees no mutation.
    /// Busy refusals also have a genuine journal entry and an admission callback (B-043).
    public func execute(_ plan: OperationPlan,
                        progress: @Sendable (OperationProgress) async -> Void = { _ in },
                        admission: @Sendable (OperationID, OperationPlan) async -> Bool = { _, _ in true }) async -> OperationResult {
        // Actor reentrancy must not interleave two mutation sequences.
        guard !running, !quarantined else {
            let id = await journal.begin(plan)
            _ = await admission(id, plan)
            return await refuse(plan, id: id, error: .busy)
        }
        running = true
        defer { running = false }
        let id = await journal.begin(plan)
        guard await admission(id, plan) else { return await refuse(plan, id: id, error: .invalidPlan) }
        var outcomes: [ItemOutcome] = []
        var expectedTokens: [String: ChangeToken] = [:]
        for (url, value) in plan.expectedTokens { expectedTokens[url.evidenceKey] = value }
        var expectedKinds: [String: FileEntryKind] = [:]
        for (url, value) in plan.expectedKinds { expectedKinds[url.evidenceKey] = value }
        var forward = await ForwardEvidence.capture(plan, fileSystem: fileSystem)
        let cache = ExecutionCache(fileSystem: fileSystem, context: plan.context)
        var failure: OperationError? = plan.isExecutable ? nil : .invalidPlan
        if failure == nil {
            for (url, token) in plan.expectedTokens {
                do {
                    let current = try await fileSystem.entry(at: url)
                    try validateUndoKind(current, expectedKind: expectedKinds[url.evidenceKey], policy: plan.undoVerification)
                    if plan.undoVerification != .sameObject, current.changeToken != token { failure = .sourceChanged(url); break }
                    if plan.undoVerification == .leafOnly {
                        let evidence = try forward.precondition(for: url)
                        guard evidence.changeToken == token, evidence.kind == expectedKinds[url.evidenceKey] else {
                            throw OperationError.verificationUnavailable
                        }
                    }
                    try await forward.validate(url, fileSystem: fileSystem)
                } catch is CancellationError {
                    failure = .cancelled; break
                } catch { failure = (error as? OperationError) ?? .sourceChanged(url); break }
            }
        }
        for step in plan.steps {
            if failure == nil && Task.isCancelled { failure = .cancelled }
            if failure != nil {
                outcomes.append(ItemOutcome(step: step, destination: step.destination, result: .failure(.notAttempted)))
                continue
            }
            await progress(OperationProgress(id: id, itemsDone: outcomes.count, itemsTotal: plan.steps.count,
                                             currentName: step.source?.lastPathComponent ?? step.destination?.lastPathComponent))
            do {
                try Task.checkCancellation()
                let destination = try await perform(step, context: plan.context, expectedTokens: expectedTokens, expectedKinds: expectedKinds, undoVerification: plan.undoVerification, forward: forward, cache: cache)
                // Mutation success must survive a metadata read failure or cancellation.
                let metadata: FileEntry?
                if let destination {
                    let fs = fileSystem
                    // Preserve completed output evidence even when the caller cancelled mid-primitive.
                    metadata = await Task { try? await fs.entry(at: destination) }.value
                } else { metadata = nil }
                forward.completed(step, destination: destination, entry: metadata)
                await cache.completed(step, destination: destination)
                let token = metadata?.changeToken
                if let source = step.source, let expected = expectedTokens[source.evidenceKey],
                   step.kind == .move || step.kind == .trash {
                    let kind = expectedKinds.removeValue(forKey: source.evidenceKey)
                    expectedTokens[source.evidenceKey] = nil
                    if let destination {
                        expectedTokens[destination.evidenceKey] = token ?? expected
                        expectedKinds[destination.evidenceKey] = metadata?.kind ?? kind
                    }
                }
                let outcome = ItemOutcome(step: step, destination: destination, result: .success(token), destinationKind: metadata?.kind,
                                          destinationEvidence: metadata.flatMap { value in
                    value.objectIdentity.map { FileMutationPrecondition(identity: $0, changeToken: value.changeToken, kind: value.kind) }
                })
                outcomes.append(outcome)
                await journal.record(outcome, for: id)
            } catch {
                let executionFailure = error as? StepExecutionFailure
                let cause = executionFailure?.underlying ?? error
                let mapped: OperationError
                if cause is CancellationError { mapped = .cancelled }
                else if let value = cause as? OperationError { mapped = value }
                else if let value = cause as? ConditionalMutationError {
                    switch value {
                    case .unsupported: mapped = .verificationUnavailable
                    case .sourceChanged: mapped = step.source.map(OperationError.sourceChanged) ?? .invalidPlan
                    case .cancelledBeforeMutation: mapped = .cancelled
                    }
                }
                else if let value = cause as? FileSystemError, value == .timedOut { mapped = .timedOut }
                else { mapped = .other(String(describing: cause)) }
                // A thrown filesystem mutation may have partially completed. Never automatically retry it.
                // Timeout may finish late: this executor remains quarantined until external reconciliation.
                if mapped == .timedOut || (mapped == .cancelled && executionFailure != nil && !(cause is ConditionalMutationError)) { quarantined = true }
                failure = mapped
                // Read-only refusals cannot leave an uncertain mutation. Missing evidence for
                // an earlier completed output still requires reconciliation (B-038/B-041).
                let uncertain = (executionFailure != nil && !(cause is ConditionalMutationError) && mapped != .conflict)
                    || (mapped == .verificationUnavailable && (forward.isMissing(step.source) || forward.isMissing(step.destination)))
                let outcome = ItemOutcome(step: step, destination: executionFailure?.destination ?? step.destination,
                                          result: .failure(mapped), requiresReconciliation: uncertain)
                outcomes.append(outcome); await journal.record(outcome, for: id)
            }
        }
        let result = OperationResult(id: id, command: plan.command, outcomes: outcomes, error: failure)
        await journal.complete(result)
        await progress(OperationProgress(id: id, itemsDone: outcomes.filter(\.succeeded).count, itemsTotal: plan.steps.count, currentName: nil))
        return result
    }
    private func refuse(_ plan: OperationPlan, id: OperationID, error: OperationError) async -> OperationResult {
        let result = OperationResult(id: id, command: plan.command, outcomes: plan.steps.map {
            ItemOutcome(step: $0, destination: $0.destination, result: .failure(.notAttempted))
        }, error: error)
        await journal.complete(result)
        return result
    }
    /// Root-owned macOS spellings of `/private/...`; without them every temp path is refused (FB1-11).
    /// Any other symlinked ancestor stays refused so it cannot redirect a mutation (B-039).
    private static let osManagedAncestorSymlinks: Set<String> = ["/tmp", "/var", "/etc"]
    private func perform(_ step: PlannedStep, context: PlanningContext, expectedTokens: [String: ChangeToken],
                         expectedKinds: [String: FileEntryKind], undoVerification: UndoVerificationPolicy, forward: ForwardEvidence, cache: ExecutionCache) async throws -> URL? {
        for url in [step.source, step.destination].compactMap({ $0 }) {
            guard url.isFileURL, url.standardizedFileURL.path != "/" else { throw OperationError.invalidPlan }
        }
        for url in [step.source, step.destination].compactMap({ $0 }) {
            var parent = url.deletingLastPathComponent()
            while parent.path != "/" {
                let entry = try await fileSystem.entry(at: parent)
                guard entry.kind == .directory || entry.kind == .package
                    || (entry.kind == .symlinkToDirectory && Self.osManagedAncestorSymlinks.contains(parent.path)) else {
                    throw OperationError.invalidPlan
                }
                parent.deleteLastPathComponent()
            }
        }
        if let source = step.source, let target = step.destination {
            // Equality and containment are interpreted in the source namespace. A destination
            // on another volume must not change how the source's ancestors are compared.
            let sensitive = await cache.sensitivity(at: source.deletingLastPathComponent())
            let sourcePath = FileNameComparison.key(source.standardizedFileURL.path, caseSensitive: sensitive)
            let targetPath = FileNameComparison.key(target.standardizedFileURL.path, caseSensitive: sensitive)
            guard targetPath != sourcePath, !targetPath.hasPrefix(sourcePath + "/") else { throw OperationError.invalidPlan }
        }
        if step.kind == .trash {
            guard let source = step.source else { throw OperationError.invalidPlan }
            if let destination = step.verificationDestination {
                try await verify(source: source, destination: destination, cache: cache)
                try await forward.validate(destination, fileSystem: fileSystem)
            }
            if undoVerification != .sameObject, let token = expectedTokens[source.evidenceKey] {
                let current = try await fileSystem.entry(at: source)
                guard current.changeToken == token else { throw OperationError.sourceChanged(source) }
                // Root tokens cannot authorize retirement of potentially edited descendants.
                // Complete identity/content manifests require a separately reviewed public contract.
                guard current.kind != .directory && current.kind != .package else {
                    throw OperationError.verificationUnavailable
                }
            }
            try await validateExpectedSource(step.source, tokens: expectedTokens, kinds: expectedKinds, policy: undoVerification)
            try await forward.validate(source, fileSystem: fileSystem)
            let evidence = try await forward.precondition(for: source, fileSystem: fileSystem)
            try Task.checkCancellation()
            let trashed: URL?
            do { trashed = try await fileSystem.mutate(.trash, source: source, requiring: evidence) }
            catch { throw StepExecutionFailure(destination: nil, underlying: error) }
            if let trashed { await origins.record([TrashedItem(trashedURL: trashed, originalURL: source)]) }
            return trashed
        }
        guard var destination = step.destination else { throw OperationError.invalidPlan }
        if step.kind == .verifyCopy {
            guard let source = step.source else { throw OperationError.invalidPlan }
            try await forward.validate(destination, fileSystem: fileSystem)
            try await verify(source: source, destination: destination, cache: cache)
            try await forward.validate(source, fileSystem: fileSystem)
            try await forward.validate(destination, fileSystem: fileSystem)
            return destination
        }
        let parent = destination.deletingLastPathComponent()
        // Recheck complete no-follow names; exclusive FS mutations arbitrate subsequent races.
        let occupied = try await cache.names(at: parent)
        let sensitive = await cache.sensitivity(at: parent)
        if occupied.contains(FileNameComparison.key(destination.lastPathComponent, caseSensitive: sensitive)) {
            guard step.retryKeepBoth else { throw OperationError.conflict }
            destination = parent.appendingPathComponent(try UniqueNamer.name(for: (step.collisionName ?? step.source?.lastPathComponent ?? destination.lastPathComponent),
                exists: { occupied.contains(FileNameComparison.key($0, caseSensitive: sensitive)) }).value)
        }
        for attempt in 0..<16 {
            do {
                try Task.checkCancellation()
                try await mutate(step, destination: destination, expectedTokens: expectedTokens, expectedKinds: expectedKinds, undoVerification: undoVerification, forward: forward)
                return destination
            } catch let failure as StepExecutionFailure where failure.underlying is ExclusiveDestinationConflict || (failure.underlying as? FileSystemError) == .collision(noMutation: true) {
                guard step.retryKeepBoth, attempt < 15 else {
                    throw StepExecutionFailure(destination: destination, underlying: OperationError.conflict)
                }
                var names = try await cache.names(at: parent, refresh: true)
                names.insert(FileNameComparison.key(destination.lastPathComponent, caseSensitive: sensitive))
                let raw = step.collisionName ?? step.source?.lastPathComponent ?? step.destination?.lastPathComponent ?? ""
                let name = try UniqueNamer.name(for: raw, exists: { names.contains(FileNameComparison.key($0, caseSensitive: sensitive)) })
                destination = parent.appendingPathComponent(name.value)
            }
        }
        throw OperationError.conflict
    }
    private func validateUndoKind(_ current: FileEntry, expectedKind: FileEntryKind?,
                                  policy: UndoVerificationPolicy) throws {
        guard policy == .leafOnly else { return }
        guard current.kind != .directory, current.kind != .package,
              let expectedKind, expectedKind != .directory, expectedKind != .package else {
            throw OperationError.verificationUnavailable
        }
        guard current.kind == expectedKind else { throw OperationError.sourceChanged(current.url) }
    }
    private func validateExpectedSource(_ source: URL?, tokens: [String: ChangeToken],
                                        kinds: [String: FileEntryKind], policy: UndoVerificationPolicy) async throws {
        guard let source else { throw OperationError.invalidPlan }
        guard let token = tokens[source.evidenceKey] else {
            if policy != .none { throw OperationError.verificationUnavailable }
            return
        }
        // Identity is checked by ForwardEvidence; contents may legitimately have changed.
        if policy == .sameObject { return }
        let current: FileEntry
        do { current = try await fileSystem.entry(at: source) }
        catch is CancellationError { throw CancellationError() }
        catch { throw OperationError.sourceChanged(source) }
        try validateUndoKind(current, expectedKind: kinds[source.evidenceKey], policy: policy)
        guard current.changeToken == token else { throw OperationError.sourceChanged(source) }
    }
    private func verify(source: URL, destination: URL, cache: ExecutionCache) async throws {
        let manifest = await cache.manifest(for: source)
        guard !manifest.isEmpty else { throw OperationError.verificationUnavailable }
        for original in manifest {
            let current = try await fileSystem.entry(at: original.source)
            guard current.changeToken == original.changeToken else { throw OperationError.verificationFailed }
        }
        // Fable/Opus: K5 cannot atomically compare identity and retire a source; native coordination is still needed.
        try await verifier.verify(source: source, destination: destination)
    }
    private func mutate(_ step: PlannedStep, destination: URL, expectedTokens: [String: ChangeToken],
                        expectedKinds: [String: FileEntryKind], undoVerification: UndoVerificationPolicy, forward: ForwardEvidence) async throws {
        switch step.kind {
        case .copy:
            guard let source = step.source else { throw OperationError.invalidPlan }
            try await forward.validate(source, fileSystem: fileSystem)
            let evidence = try forward.precondition(for: source)
            try Task.checkCancellation()
            do { try await copier.copy(from: source, to: destination, requiring: evidence) }
            catch { throw StepExecutionFailure(destination: destination, underlying: error) }
        case .move:
            guard let source = step.source else { throw OperationError.invalidPlan }
            let sourceVolume = try await fileSystem.volumeIdentifier(for: source)
            let destinationVolume = try await fileSystem.volumeIdentifier(for: destination.deletingLastPathComponent())
            guard sourceVolume == destinationVolume else { throw OperationError.invalidPlan }
            try await validateExpectedSource(source, tokens: expectedTokens, kinds: expectedKinds, policy: undoVerification)
            try await forward.validate(source, fileSystem: fileSystem)
            let evidence = try await forward.precondition(for: source, fileSystem: fileSystem)
            try Task.checkCancellation()
            do { _ = try await fileSystem.mutate(.move(to: destination), source: source, requiring: evidence) }
            catch { throw StepExecutionFailure(destination: destination, underlying: error) }
        case .createDirectory:
            do { try await fileSystem.createDirectory(at: destination) }
            catch { throw StepExecutionFailure(destination: destination, underlying: error) }
        case .createFile:
            do { try await fileSystem.createFileExclusively(at: destination, contents: step.contents) }
            catch { throw StepExecutionFailure(destination: destination, underlying: error) }
        case .trash, .verifyCopy: throw OperationError.invalidPlan
        }
    }
}

private struct StepExecutionFailure: Error {
    let destination: URL?
    let underlying: Error
}
