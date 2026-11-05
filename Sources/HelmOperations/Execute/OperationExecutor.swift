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
                origins: any TrashOriginRecording = InMemoryTrashOrigins(), journal: OperationJournal = OperationJournal()) {
        self.fileSystem = fileSystem; self.copier = copier ?? FoundationFileCopier(fileSystem: fileSystem)
        self.verifier = verifier ?? TreeCopyVerifier(fileSystem: fileSystem); self.origins = origins; self.journal = journal
    }
    public func execute(_ plan: OperationPlan,
                        progress: @Sendable (OperationProgress) async -> Void = { _ in }) async -> OperationResult {
        // Actor reentrancy must not interleave two mutation sequences.
        guard !running, !quarantined else { return OperationResult(id: OperationID(), command: plan.command, outcomes: [], error: .busy) }
        running = true
        defer { running = false }
        let id = await journal.begin(plan)
        var outcomes: [ItemOutcome] = []
        var expectedTokens = plan.expectedTokens
        var expectedKinds = plan.expectedKinds
        var forward = await ForwardEvidence.capture(plan, fileSystem: fileSystem)
        var failure: OperationError? = plan.isExecutable ? nil : .invalidPlan
        if failure == nil {
            for (url, token) in plan.expectedTokens {
                do {
                    let current = try await fileSystem.entry(at: url)
                    try validateUndoKind(current, expectedKind: expectedKinds[url], policy: plan.undoVerification)
                    if current.changeToken != token { failure = .sourceChanged(url); break }
                    if plan.undoVerification != .none {
                        let evidence = try forward.precondition(for: url)
                        guard evidence.changeToken == token, evidence.kind == expectedKinds[url] else {
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
                let destination = try await perform(step, context: plan.context, expectedTokens: expectedTokens, expectedKinds: expectedKinds, undoVerification: plan.undoVerification, forward: forward)
                // Mutation success must survive a metadata read failure or cancellation.
                let metadata: FileEntry?
                if let destination { metadata = try? await fileSystem.entry(at: destination) } else { metadata = nil }
                forward.completed(step, destination: destination, entry: metadata)
                let token = metadata?.changeToken
                if let source = step.source, let expected = expectedTokens[source],
                   step.kind == .move || step.kind == .trash {
                    let kind = expectedKinds.removeValue(forKey: source)
                    expectedTokens[source] = nil
                    if let destination {
                        expectedTokens[destination] = token ?? expected
                        expectedKinds[destination] = metadata?.kind ?? kind
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
                let uncertain: Bool
                switch mapped {
                case .cancelled: uncertain = executionFailure != nil
                case .verificationUnavailable: uncertain = forward.isMissing(step.source) || forward.isMissing(step.destination)
                case .invalidPlan, .conflict, .verificationFailed: uncertain = false
                default: uncertain = true
                }
                let outcome = ItemOutcome(step: step, destination: executionFailure?.destination ?? step.destination,
                                          result: .failure(mapped), requiresReconciliation: cause is ConditionalMutationError ? false : uncertain)
                outcomes.append(outcome); await journal.record(outcome, for: id)
            }
        }
        let result = OperationResult(id: id, command: plan.command, outcomes: outcomes, error: failure)
        await journal.complete(result)
        await progress(OperationProgress(id: id, itemsDone: outcomes.filter(\.succeeded).count, itemsTotal: plan.steps.count, currentName: nil))
        return result
    }
    private func perform(_ step: PlannedStep, context: PlanningContext, expectedTokens: [URL: ChangeToken],
                         expectedKinds: [URL: FileEntryKind], undoVerification: UndoVerificationPolicy, forward: ForwardEvidence) async throws -> URL? {
        for url in [step.source, step.destination].compactMap({ $0 }) {
            guard url.isFileURL, url.standardizedFileURL.path != "/" else { throw OperationError.invalidPlan }
        }
        for url in [step.source, step.destination].compactMap({ $0 }) {
            var parent = url.deletingLastPathComponent()
            while parent.path != "/" {
                let entry = try await fileSystem.entry(at: parent)
                guard entry.kind == .directory || entry.kind == .package else { throw OperationError.invalidPlan }
                parent.deleteLastPathComponent()
            }
        }
        if let source = step.source, let target = step.destination {
            // Equality and containment are interpreted in the source namespace. A destination
            // on another volume must not change how the source's ancestors are compared.
            let sensitive = await sensitivity(at: source.deletingLastPathComponent(), context: context)
            let sourcePath = FileNameComparison.key(source.standardizedFileURL.path, caseSensitive: sensitive)
            let targetPath = FileNameComparison.key(target.standardizedFileURL.path, caseSensitive: sensitive)
            guard targetPath != sourcePath, !targetPath.hasPrefix(sourcePath + "/") else { throw OperationError.invalidPlan }
        }
        if step.kind == .trash {
            guard let source = step.source else { throw OperationError.invalidPlan }
            if let destination = step.verificationDestination {
                try await verify(source: source, destination: destination, context: context)
            }
            if let token = expectedTokens[source] {
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
            let evidence = try forward.precondition(for: source)
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
            try await verify(source: source, destination: destination, context: context)
            try await forward.validate(source, fileSystem: fileSystem)
            try await forward.validate(destination, fileSystem: fileSystem)
            return destination
        }
        let parent = destination.deletingLastPathComponent()
        // Recheck complete no-follow names; exclusive FS mutations arbitrate subsequent races.
        let occupied = try await fileSystem.childNames(of: parent)
        let sensitive = await sensitivity(at: parent, context: context)
        if occupied.contains(where: { FileNameComparison.key($0, caseSensitive: sensitive) == FileNameComparison.key(destination.lastPathComponent, caseSensitive: sensitive) }) {
            guard step.retryKeepBoth else { throw OperationError.conflict }
            destination = parent.appendingPathComponent(try UniqueNamer.name(for: (step.collisionName ?? step.source?.lastPathComponent ?? destination.lastPathComponent),
                existingNames: occupied, caseSensitive: sensitive).value)
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
                let names = try await fileSystem.childNames(of: parent)
                let raw = step.collisionName ?? step.source?.lastPathComponent ?? step.destination?.lastPathComponent ?? ""
                let name = try UniqueNamer.name(for: raw, existingNames: names.union([destination.lastPathComponent]), caseSensitive: sensitive)
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
    private func validateExpectedSource(_ source: URL?, tokens: [URL: ChangeToken],
                                        kinds: [URL: FileEntryKind], policy: UndoVerificationPolicy) async throws {
        guard let source else { throw OperationError.invalidPlan }
        guard let token = tokens[source] else {
            if policy == .leafOnly { throw OperationError.verificationUnavailable }
            return
        }
        let current: FileEntry
        do { current = try await fileSystem.entry(at: source) }
        catch is CancellationError { throw CancellationError() }
        catch { throw OperationError.sourceChanged(source) }
        try validateUndoKind(current, expectedKind: kinds[source], policy: policy)
        guard current.changeToken == token else { throw OperationError.sourceChanged(source) }
    }
    private func sensitivity(at directory: URL, context: PlanningContext) async -> Bool {
        if let declared = context.caseSensitive.first(where: { $0.key.standardizedFileURL.path == directory.standardizedFileURL.path }) {
            return declared.value
        }
        return (try? await fileSystem.isCaseSensitive(at: directory)) ?? false
    }
    private func verify(source: URL, destination: URL, context: PlanningContext) async throws {
        let manifest = context.sourceManifest.filter { $0.source == source || $0.source.path.hasPrefix(source.path + "/") }
        guard !manifest.isEmpty else { throw OperationError.verificationUnavailable }
        for original in manifest {
            let current = try await fileSystem.entry(at: original.source)
            guard current.changeToken == original.changeToken else { throw OperationError.verificationFailed }
        }
        // Fable/Opus: K5 cannot atomically compare identity and retire a source; native coordination is still needed.
        try await verifier.verify(source: source, destination: destination)
    }
    private func mutate(_ step: PlannedStep, destination: URL, expectedTokens: [URL: ChangeToken],
                        expectedKinds: [URL: FileEntryKind], undoVerification: UndoVerificationPolicy, forward: ForwardEvidence) async throws {
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
            let evidence = try forward.precondition(for: source)
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
