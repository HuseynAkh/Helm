// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Optional enumeration capability reports skipped children without aborting a listing (F-035/B-017).
/// Providers must continue after `.warning`; a thrown error means the directory read cannot continue.
public protocol RecoverableDirectoryEnumerating: FileSystem {
    func enumerateRecoverably(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<LoadEvent, Error>
}

/// Per-tab loading worker preserves natural sorting, progressive display and stale-load rejection
/// (F-035/F-040/F-042, B-009/B-014/B-017). Create one worker per independent consumer.
public actor DirectoryLoadPipeline {
    private let fileSystem: any FileSystem
    private var task: Task<Void, Never>?
    private var continuation: AsyncStream<TabAction>.Continuation?
    private var token: UUID?

    public init(fileSystem: any FileSystem) { self.fileSystem = fileSystem }

    deinit { task?.cancel(); continuation?.finish() }

    /// Starts a cumulative, newest-only stream. A new request retires the previous worker.
    /// `generation` is the identity supplied by TabEffect.load, never allocated by this service.
    public func load(_ location: Location, generation: Generation, options: LoadOptions = LoadOptions(),
                     diagnostic: @escaping @Sendable (String) -> Void = { _ in }) -> AsyncStream<TabAction> {
        start(location, generation: generation, options: options, monitor: false, diagnostic: diagnostic)
    }

    /// Responds to refreshPaths with one complete monitor snapshot, preserving selection by ID
    /// in TabReducer. Partial monitor snapshots would prematurely discard selected IDs (B-011).
    public func reload(_ location: Location, monitorGeneration: Generation, options: LoadOptions = LoadOptions(),
                       diagnostic: @escaping @Sendable (String) -> Void = { _ in }) -> AsyncStream<TabAction> {
        start(location, generation: monitorGeneration, options: options, monitor: true, diagnostic: diagnostic)
    }

    public func cancel() {
        token = nil; task?.cancel(); task = nil
        continuation?.finish(); continuation = nil
    }

    private func start(_ location: Location, generation: Generation, options: LoadOptions,
                       monitor: Bool, diagnostic: @escaping @Sendable (String) -> Void) -> AsyncStream<TabAction> {
        cancel()
        let identity = UUID()
        token = identity
        let pair = AsyncStream<TabAction>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation = pair.continuation
        pair.continuation.onTermination = { [weak self] _ in
            Task { await self?.cancel(identity) }
        }
        let fileSystem = self.fileSystem
        task = Task.detached { [weak self] in
            do {
                guard case .directory(let url) = location else { throw FileSystemError.unsupported }
                let root = try await fileSystem.entry(at: url)
                try Task.checkCancellation()
                guard root.isReadable else { throw FileSystemError.permissionDenied }
                guard root.isDirectoryLike else { throw FileSystemError.other("Not a directory") }
                var entries: [ItemID: FileEntry] = [:]
                var threshold = options.batchSize
                let enumeration = EnumerationOptions(includeHidden: options.showHidden, batchSize: options.batchSize)
                // Only cumulative snapshots can be dropped safely; raw enumeration batches cannot.
                func consume(_ batch: [FileEntry]) async throws {
                    try Task.checkCancellation()
                    for value in batch where options.showHidden || !value.isHidden {
                        if !value.isReadable { diagnostic("Unreadable entry: \(value.url.path)") }
                        entries[value.id] = value
                    }
                    if !monitor && entries.count >= threshold {
                        let snapshot = Self.snapshot(location, entries: entries, options: options,
                                                     generation: generation, finished: false)
                        try Task.checkCancellation()
                        await self?.emit(.loadProgress(generation, snapshot), identity: identity)
                        // Geometric publication bounds total sorting work for huge directories.
                        threshold = entries.count > Int.max / 2 ? Int.max : entries.count * 2
                    }
                }
                if let recoverable = fileSystem as? any RecoverableDirectoryEnumerating {
                    for try await event in recoverable.enumerateRecoverably(url, options: enumeration) {
                        try Task.checkCancellation()
                        switch event {
                        case .batch(let batch): try await consume(batch)
                        case .warning(let message): diagnostic(message)
                        case .finished: break // stream completion, not a marker, determines success
                        }
                    }
                } else {
                    for try await batch in fileSystem.enumerate(url, options: enumeration) { try await consume(batch) }
                }
                try Task.checkCancellation()
                let snapshot = Self.snapshot(location, entries: entries, options: options,
                                             generation: generation, finished: true)
                try Task.checkCancellation()
                await self?.emit(monitor ? .monitorSnapshot(generation, snapshot) : .loadFinished(generation, snapshot),
                                 identity: identity, finished: true)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                diagnostic(String(describing: error))
                let action: TabAction = monitor
                    ? .monitorEvent(generation, .unavailable(.other(String(describing: error))))
                    : .loadFailed(generation, Self.loadError(error))
                await self?.emit(action, identity: identity, finished: true)
            }
        }
        return pair.stream
    }

    private func cancel(_ identity: UUID) { if token == identity { cancel() } }
    private func emit(_ action: TabAction, identity: UUID, finished: Bool = false) {
        guard token == identity else { return }
        continuation?.yield(action)
        if finished { continuation?.finish(); continuation = nil; task = nil; token = nil }
    }
    private nonisolated static func snapshot(_ location: Location, entries: [ItemID: FileEntry],
                                            options: LoadOptions, generation: Generation,
                                            finished: Bool) -> PresentationSnapshot {
        let built = SnapshotBuilder.build(location: location, entries: Array(entries.values), sort: options.sort,
            phase: finished ? .ready : .loading(loadedCount: entries.count))
        return PresentationSnapshot(id: generation, location: location, phase: built.phase,
                                    sort: built.sort, sortedEntries: built.sortedEntries)
    }
    private nonisolated static func loadError(_ error: Error) -> LoadError {
        switch FileSystemError.mapping(error) {
        case .notFound: return .notFound
        case .permissionDenied: return .permissionDenied
        case .timedOut: return .timedOut
        default: return .other(String(describing: error))
        }
    }
}
