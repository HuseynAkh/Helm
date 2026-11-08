#if os(macOS)
import AppKit
import HelmCore
import HelmFileSystem
import HelmOperations
import HelmPersistence

/// The app's one file-operation engine: a single executor and journal, with each window keeping its own
/// undo history (OK2-6). Operations run one at a time, in the order they were asked for.
@MainActor public final class OperationCoordinator {
    public enum Failure: Error, Equatable { case busy, cancelled, message(String) }
    /// Decides what to do about existing names, or nil to stop before anything happens.
    public typealias ConflictResolver = @MainActor ([Conflict]) async -> ConflictPolicy?
    /// Decides what to do when one item fails partway through: skip it, try it again or stop (P-139).
    public typealias FailureResolver = @MainActor (StepFailure) async -> FailureDecision

    private let executor: OperationExecutor
    private let fileSystem: any FileSystem
    private let builder: PlanningContextBuilder
    private let origins: any AppTrashOriginStoring
    private var tail: Task<Void, Never>?
    private var rows: [OperationID: OperationRowModel] = [:]
    private var order: [OperationID] = []
    private var cancellers: [OperationID: () -> Void] = [:]
    private var running: Int = 0
    public let changes: Broadcast<[OperationRowModel]> = Broadcast()
    public let inFlightChanges: Broadcast<Int> = Broadcast()
    public var inFlight: Int { running }
    public var currentRows: [OperationRowModel] { order.compactMap { rows[$0] } }

    public init(fileSystem: any FileSystem, origins: any AppTrashOriginStoring, journal: OperationJournal) {
        self.fileSystem = fileSystem; self.origins = origins
        self.builder = PlanningContextBuilder(fileSystem: fileSystem)
        self.executor = OperationExecutor(fileSystem: fileSystem, origins: origins, journal: journal)
    }

    /// Plans against the disk as it is now, asks about conflicts, runs, and records the result in `history`.
    @discardableResult
    public func run(_ command: Command, sources: [URL], destinations: [URL], history: WindowOperationHistory,
                    resolver: ConflictResolver?, onFailure: FailureResolver? = nil) async -> Result<OperationResult, Failure> {
        guard let request = await history.beginForward(command) else { return .failure(.busy) }
        return await runReserved(request: request, command: command, sources: sources, destinations: destinations,
                                 history: history, resolver: resolver, onFailure: onFailure)
    }

    private func runReserved(request: HistoryRequestID, command: Command, sources: [URL], destinations: [URL],
                             history: WindowOperationHistory, resolver: ConflictResolver?,
                             onFailure: FailureResolver? = nil) async -> Result<OperationResult, Failure> {
        running += 1; inFlightChanges.send(running)
        defer { running -= 1; inFlightChanges.send(running) }
        let plan: OperationPlan
        do {
            var context = try await builder.build(sources: sources, destinations: destinations)
            let conflicts = Self.conflicts(command, context: context)
            if !conflicts.isEmpty, let resolver {
                guard let policy = await resolver(conflicts) else {
                    await history.abortForward(request: request, failure: .cancelled)
                    return .failure(.cancelled)
                }
                context = PlanningContext(sourceManifest: context.sourceManifest, availableBytes: context.availableBytes,
                    caseSensitive: context.caseSensitive, existingNames: context.existingNames, volumeIDs: context.volumeIDs,
                    defaultPolicy: policy, existingEntries: context.existingEntries)
            }
            plan = OperationPlanner.plan(command, context: context)
        } catch {
            let message = OperationText.describe(error)
            await history.abortForward(request: request, failure: .failed(message))
            return .failure(.message(message))
        }
        guard plan.isExecutable else {
            let message = OperationText.describe(plan.issues)
            await history.abortForward(request: request, failure: .failed(message))
            return .failure(.message(message))
        }
        if plan.steps.isEmpty {
            await history.abortForward(request: request, failure: .cancelled)
            return .failure(.cancelled)
        }
        let result = await execute(plan, title: OperationText.title(for: command), admission: { id, plan in
            await history.bindExecution(request: request, operation: id, plan: plan)
        }, onFailure: onFailure)
        let entry = await executor.journal.entry(result.id)
        if let entry { await history.completeForward(request: request, entry: entry) }
        return .success(result)
    }

    public func undo(history: WindowOperationHistory) async -> Result<OperationResult, Failure> {
        let state = await history.snapshot()
        guard let top = state.undoEntries.last else { return .failure(.message("Nothing to undo.")) }
        var recorded: [URL: URL] = [:]
        if let entry = await history.entry(for: top.operationID) {
            for outcome in entry.result?.outcomes ?? [] where outcome.step.kind == .trash && outcome.succeeded {
                if let url = outcome.destination { recorded[url] = await origins.originalURL(forTrashed: url) }
            }
        }
        guard let request = await history.beginUndo(recordedOrigins: recorded) else {
            return .failure(.message("This can’t be undone, because Helm no longer has a record of where the items came from."))
        }
        running += 1; inFlightChanges.send(running)
        defer { running -= 1; inFlightChanges.send(running) }
        let result = await execute(request.plan, title: "Undo \(top.name)", admission: { id, plan in
            await history.bindExecution(request: request.request, operation: id, plan: plan)
        })
        await history.complete(request: request.request, outcome: result)
        return .success(result)
    }

    public func redo(history: WindowOperationHistory, resolver: ConflictResolver?) async -> Result<OperationResult, Failure> {
        guard let (request, command) = await history.beginRedoForward() else { return .failure(.busy) }
        let (sources, destinations) = Self.scope(of: command)
        return await runReserved(request: request, command: command, sources: sources, destinations: destinations,
                                 history: history, resolver: resolver)
    }

    /// The items a command reads and the folders it writes, which is what planning needs to look at.
    public static func scope(of command: Command) -> (sources: [URL], destinations: [URL]) {
        switch command {
        case .copy(let sources, let directory), .move(let sources, let directory): return (sources, [directory])
        case .duplicate(let sources): return (sources, Array(Set(sources.map { $0.deletingLastPathComponent() })))
        case .trash(let items): return (items, [])
        case .rename(let pair): return ([pair.source], [pair.source.deletingLastPathComponent()])
        case .batchRename(let pairs):
            return (pairs.map(\.source), Array(Set(pairs.map { $0.source.deletingLastPathComponent() })))
        case .createFolder(let parent, _): return ([], [parent])
        case .createFile(let parent, _, let template): return (template.map { [$0] } ?? [], [parent])
        case .recovery: return ([], [])
        }
    }

    public func cancel(_ id: OperationID) {
        cancellers[id]?()
        if let row = rows[id] {
            rows[id] = OperationRowModel(id: id, title: row.title, progress: row.progress, result: row.result, cancellationRequested: true)
            publish()
        }
    }
    public func dismiss(_ id: OperationID) {
        rows[id] = nil; order.removeAll { $0 == id }; publish()
    }

    private func execute(_ plan: OperationPlan, title: String,
                         admission: @escaping @Sendable (OperationID, OperationPlan) async -> Bool,
                         onFailure: FailureResolver? = nil) async -> OperationResult {
        let previous = tail
        let executor = executor
        let box = OperationBox()
        let task = Task { [weak self] () -> OperationResult in
            await previous?.value
            return await executor.execute(plan, progress: { progress in
                await MainActor.run { self?.update(progress, title: title) }
            }, admission: { id, plan in
                await MainActor.run { self?.register(id, title: title, box: box) }
                return await admission(id, plan)
            }, decide: { failure in
                // With nothing left and nothing to retry, Skip and Stop are the same: don't ask.
                guard let onFailure, failure.remaining > 0 || failure.canRetry else { return .stop }
                return await onFailure(failure)
            })
        }
        box.cancel = { task.cancel() }
        tail = Task { _ = await task.value }
        let result = await task.value
        cancellers[result.id] = nil
        let progress = rows[result.id]?.progress
        rows[result.id] = OperationRowModel(id: result.id, title: title, progress: progress, result: result)
        if rows[result.id] != nil && !order.contains(result.id) { order.append(result.id) }
        // Finished work leaves the panel by itself. Failures stay until dismissed.
        if result.error == nil { rows[result.id] = nil; order.removeAll { $0 == result.id } }
        publish()
        return result
    }
    private func register(_ id: OperationID, title: String, box: OperationBox) {
        cancellers[id] = { box.cancel?() }
        rows[id] = OperationRowModel(id: id, title: title)
        order.append(id)
        publish()
    }
    private func update(_ progress: OperationProgress, title: String) {
        guard rows[progress.id] != nil else { return }
        rows[progress.id] = OperationRowModel(id: progress.id, title: title, progress: progress,
                                              cancellationRequested: rows[progress.id]?.cancellationRequested ?? false)
        publish()
    }
    private func publish() { changes.send(currentRows) }

    private static func conflicts(_ command: Command, context: PlanningContext) -> [Conflict] {
        let sources: [URL]; let parent: URL
        switch command {
        case .copy(let values, let directory), .move(let values, let directory): sources = values; parent = directory
        default: return []
        }
        guard let names = context.existingNames.first(where: { $0.key.standardizedFileURL.path == parent.standardizedFileURL.path })?.value else { return [] }
        let sensitive = context.caseSensitive.first(where: { $0.key.standardizedFileURL.path == parent.standardizedFileURL.path })?.value ?? false
        let occupied = Set(names.map { FileNameComparison.key($0, caseSensitive: sensitive) })
        return sources.compactMap { source in
            // Moving onto itself isn't a conflict; the planner reports it on its own.
            guard source.deletingLastPathComponent().standardizedFileURL.path != parent.standardizedFileURL.path,
                  occupied.contains(FileNameComparison.key(source.lastPathComponent, caseSensitive: sensitive)) else { return nil }
            return Conflict(source: source, destination: parent.appendingPathComponent(source.lastPathComponent))
        }
    }
}

private final class OperationBox: @unchecked Sendable { var cancel: (() -> Void)? }

/// Whether a run asked about a failure, so the window doesn't report the same failure twice.
@MainActor final class FailurePromptRecord { var didAsk = false }

/// Words for operations, in one place so they read the same everywhere.
public enum OperationText {
    /// The past participle for "couldn't be …", as in "“Report.pdf” couldn’t be copied."
    public static func verb(for command: Command) -> String {
        switch command {
        case .copy: return "copied"
        case .move: return "moved"
        case .duplicate: return "duplicated"
        case .trash: return "moved to the Trash"
        case .rename, .batchRename: return "renamed"
        case .createFolder, .createFile: return "created"
        case .recovery: return "recovered"
        }
    }
    public static func title(for command: Command) -> String {
        switch command {
        case .copy(let sources, _): return count("Copying", sources)
        case .move(let sources, _): return count("Moving", sources)
        case .duplicate(let sources): return count("Duplicating", sources)
        case .trash(let items): return count("Moving to Trash:", items)
        case .rename(let pair): return "Renaming “\(pair.source.lastPathComponent)”"
        case .batchRename(let pairs): return "Renaming \(pairs.count) items"
        case .createFolder(_, let name): return "Creating “\(name.value)”"
        case .createFile(_, let name, _): return "Creating “\(name.value)”"
        case .recovery: return "Recovering"
        }
    }
    private static func count(_ verb: String, _ urls: [URL]) -> String {
        urls.count == 1 ? "\(verb) “\(urls[0].lastPathComponent)”" : "\(verb) \(urls.count) items"
    }
    public static func describe(_ issues: [PlanningIssue]) -> String {
        guard let issue = issues.first(where: \.isBlocking) else { return "This can’t be done." }
        switch issue {
        case .virtualLocationTarget: return "Items can’t be placed here. Choose a folder."
        case .invalidURL(let url): return "“\(url.lastPathComponent)” isn’t a local item."
        case .missingSnapshot(let url): return "Helm couldn’t read “\(url.lastPathComponent)”."
        case .overlappingSelection(let url): return "“\(url.lastPathComponent)” overlaps another selected item."
        case .destinationInsideSource(let url): return "A folder can’t be placed inside itself: “\(url.lastPathComponent)”."
        case .sourceEqualsDestination(let url): return "“\(url.lastPathComponent)” can’t replace itself."
        case .collision(let url): return "An item in “\(url.lastPathComponent)” already has that name."
        case .stopped: return "Stopped."
        case .sameParentMove(let url): return "“\(url.lastPathComponent)” is already here."
        case .invalidName: return "That name can’t be used."
        case .insufficientSpace(let url): return "There isn’t enough free space in “\(url.lastPathComponent)”."
        }
    }
    public static func describe(_ error: Error) -> String {
        switch FileSystemError.mapping(error) {
        case .permissionDenied: return "You don’t have permission to do that."
        case .notFound: return "The item no longer exists."
        case .timedOut: return "The disk stopped responding."
        case .collision: return "An item with that name already exists."
        case .unsupported: return "This disk doesn’t support that."
        case .other(let message): return message
        }
    }
}
#endif
