#if os(macOS)
import AppKit
import HelmCore
import HelmFileSystem
import HelmPersistence
import HelmSearch

/// The effects `DirectoryEffectRunner` doesn't own: loading, search, completions and recents.
/// Everything long-running stays off the main actor and replies with the reducer's own generations.
@MainActor final class HostEffectRunner: EffectRunner {
    private let dependencies: WindowDependencies
    weak var window: BrowserWindowController?

    init(dependencies: WindowDependencies) { self.dependencies = dependencies }

    func run(_ effect: StoreEffect, send: @escaping @Sendable (WindowStoreAction) -> Void) -> StoreEffectCancellation? {
        switch effect {
        case .window(.closeWindow):
            window?.closeFromStore()
            return nil
        case .window, .persistSession:
            return nil
        case .tab(let tab, let action):
            return run(action, tab: tab, send: send)
        }
    }

    private func run(_ effect: TabEffect, tab: TabID, send: @escaping @Sendable (WindowStoreAction) -> Void) -> StoreEffectCancellation? {
        switch effect {
        case .load(let location, let generation, let options):
            return load(location, generation: generation, options: options, tab: tab, send: send)
        case .loadChildren(let url, let id, let generation, let options):
            return loadChildren(url, id: id, generation: generation, options: options, tab: tab, send: send)
        case .startSearch(let query, let generation):
            return search(query, generation: generation, tab: tab, send: send)
        case .recordRecent(let url):
            dependencies.recents.recordAccess(to: url, kind: .directory, at: dependencies.clock.now())
            return nil
        case .persistShowHidden(let value):
            dependencies.settings.set(.bool(value), for: .showHiddenFiles)
            return nil
        case .addressEditor(let editor):
            return runAddress(editor, tab: tab, send: send)
        case .cancel, .startMonitor, .validateNavigation, .refreshPaths:
            return nil
        }
    }

    // MARK: Loading

    private func load(_ location: Location, generation: Generation, options: LoadOptions, tab: TabID,
                      send: @escaping @Sendable (WindowStoreAction) -> Void) -> StoreEffectCancellation {
        let task: Task<Void, Never>
        switch location {
        case .directory:
            let pipeline = DirectoryLoadPipeline(fileSystem: dependencies.fileSystem)
            task = Task.detached {
                let stream = await pipeline.load(location, generation: generation, options: options)
                for await action in stream { send(.tab(tab, action)) }
            }
        case .recent:
            let source = RecentSource(records: dependencies.recents, fileSystem: dependencies.fileSystem)
            task = Self.loadVirtual(source, location: location, generation: generation, options: options, tab: tab, send: send)
        case .trash:
            let roots = dependencies.volumes.volumes.filter { !$0.isInternal }.map(\.url)
            let source = TrashSource(fileSystem: dependencies.fileSystem, origins: dependencies.trashOrigins,
                                     home: dependencies.home, volumeRoots: roots, userID: String(getuid()))
            task = Self.loadVirtual(source, location: location, generation: generation, options: options, tab: tab, send: send)
        }
        return StoreEffectCancellation { task.cancel() }
    }

    private nonisolated static func loadVirtual(_ source: any LocationSource, location: Location, generation: Generation,
                                                options: LoadOptions, tab: TabID,
                                                send: @escaping @Sendable (WindowStoreAction) -> Void) -> Task<Void, Never> {
        Task.detached {
            do {
                var entries: [FileEntry] = []
                for try await event in source.load(location, options: options) {
                    if case .batch(let batch) = event { entries += batch }
                }
                try Task.checkCancellation()
                let built = SnapshotBuilder.build(location: location, entries: entries, sort: options.sort)
                let snapshot = PresentationSnapshot(id: generation, location: location, sort: built.sort,
                                                    sortedEntries: built.sortedEntries, rootCount: built.rootCount)
                send(.tab(tab, .loadFinished(generation, snapshot)))
            } catch is CancellationError {
                return
            } catch {
                send(.tab(tab, .loadFailed(generation, loadError(error))))
            }
        }
    }

    private func loadChildren(_ url: URL, id: ItemID, generation: Generation, options: LoadOptions, tab: TabID,
                              send: @escaping @Sendable (WindowStoreAction) -> Void) -> StoreEffectCancellation {
        let fileSystem = dependencies.fileSystem
        let task = Task.detached {
            do {
                var entries: [FileEntry] = []
                let enumeration = EnumerationOptions(includeHidden: options.showHidden, batchSize: options.batchSize)
                for try await batch in fileSystem.enumerate(url, options: enumeration) { entries += batch }
                try Task.checkCancellation()
                send(.tab(tab, .childrenLoaded(id, generation, entries)))
            } catch is CancellationError {
                return
            } catch {
                send(.tab(tab, .childrenFailed(id, generation, loadError(error))))
            }
        }
        return StoreEffectCancellation { task.cancel() }
    }


    // MARK: Search

    private func search(_ query: SearchQuery, generation: Generation, tab: TabID,
                        send: @escaping @Sendable (WindowStoreAction) -> Void) -> StoreEffectCancellation {
        let fileSystem = dependencies.fileSystem
        let clock = dependencies.clock
        let home = dependencies.home
        let volumes = dependencies.volumes.volumes.filter { !$0.isInternal }.map(\.url)
        let spotlight = SpotlightSearch(query: query)
        // Current-folder searches also walk the folder, which finds what Spotlight hasn't indexed.
        let walk = Task.detached { () -> [SearchCandidate] in
            let resolver = SearchRootResolver(home: home, computerRoots: [home], removableVolumeRoots: volumes)
            let engine = SearchEngine(fileSystem: fileSystem, resolver: resolver, clock: clock)
            let request = SearchRequest(query: query)
            guard case .currentFolder = query.scope else { return [] }
            let batch = try? await engine.collect(request, context: SearchRankingContext(query: query))
            return batch?.results.map { SearchCandidate(entry: $0.entry, isDocumentLike: $0.isDocumentLike) } ?? []
        }
        let task = Task.detached {
            let walked = await walk.value
            try? Task.checkCancellation()
            guard !Task.isCancelled else { return }
            send(.tab(tab, .searchResults(generation, rank(walked, query: query, clock: clock))))
            for await urls in await spotlight.updates() {
                guard !Task.isCancelled else { break }
                var merged = walked
                var seen = Set(walked.map(\.entry.id))
                for url in urls {
                    guard let entry = try? await fileSystem.entry(at: url), seen.insert(entry.id).inserted else { continue }
                    merged.append(SearchCandidate(entry: entry))
                }
                send(.tab(tab, .searchResults(generation, rank(merged, query: query, clock: clock))))
            }
        }
        return StoreEffectCancellation {
            walk.cancel(); task.cancel()
            Task { await spotlight.stop() }
        }
    }

    // MARK: Location bar

    private func runAddress(_ effect: AddressEditorEffect, tab: TabID,
                            send: @escaping @Sendable (WindowStoreAction) -> Void) -> StoreEffectCancellation? {
        switch effect {
        case .requestCompletions(let request):
            let engine = PathCompletionEngine(listing: LiveCompletionListing(fileSystem: dependencies.fileSystem))
            let task = Task.detached {
                do {
                    let rows = try await engine.complete(request)
                    try Task.checkCancellation()
                    send(.tab(tab, .addressBar(.completions(request.generation, rows))))
                } catch is CancellationError {
                    return
                } catch {
                    send(.tab(tab, .addressBar(.completionFailed(request.generation, "Can’t read that folder"))))
                }
            }
            return StoreEffectCancellation { task.cancel() }
        case .validate(let url, let generation):
            let fileSystem = dependencies.fileSystem
            Task.detached {
                guard let entry = try? await fileSystem.entry(at: url) else {
                    send(.tab(tab, .addressBar(.validated(generation, url, .invalid))))
                    return
                }
                let kind: AddressCommitKind = entry.isDirectoryLike ? .directory : (entry.kind == .danglingSymlink ? .invalid : .file)
                // What was typed may differ from the disk by case, Unicode form or a symlink. Go where it really is.
                send(.tab(tab, .addressBar(.resolved(generation, requested: url, canonical: CanonicalPath.resolve(url), kind))))
            }
            return nil
        case .openFile(let url):
            window?.revealTypedFile(url, in: tab)
            return nil
        case .connect(let url):
            window?.connect(to: url)
            return nil
        case .invalidPathFeedback:
            window?.locationBarRejected()
            return nil
        case .cancelled, .cancelCompletions, .navigate:
            return nil
        }
    }
}

/// The path as the file system spells it. Finder also lands on the real folder, so paths never run through a link.
enum CanonicalPath {
    static func resolve(_ url: URL) -> URL {
        let directory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard let real = realpath(url.path, nil) else { return url }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: directory)
    }
}

func loadError(_ error: Error) -> LoadError {
    switch FileSystemError.mapping(error) {
    case .notFound: return .notFound
    case .permissionDenied: return .permissionDenied
    case .timedOut: return .timedOut
    case .collision, .unsupported: return .other(String(describing: error))
    case .other(let message): return .other(message)
    }
}

private func rank(_ candidates: [SearchCandidate], query: SearchQuery, clock: any HelmClock) -> [SearchResult] {
    SearchRanker.rank(candidates, context: SearchRankingContext(query: query), clock: clock).results
}

/// Lists a folder for the location bar's completions.
struct LiveCompletionListing: DirectoryListing {
    let fileSystem: any FileSystem
    func children(of url: URL, includeHidden: Bool) async throws -> [CompletionCandidate] {
        var result: [CompletionCandidate] = []
        let options = EnumerationOptions(includeHidden: includeHidden, resolveSymlinkTargets: true)
        for try await batch in fileSystem.enumerate(url, options: options) {
            result += batch.map {
                CompletionCandidate(name: $0.name, url: $0.url, isDirectory: $0.kind == .directory,
                                    isHidden: $0.isHidden, symlinkTargetIsDirectory: $0.kind == .symlinkToDirectory)
            }
        }
        return result
    }
}

/// Live Spotlight results as a stream: each element is the full current result set (OK1-3).
/// NSMetadataQuery belongs on the main thread, so the query lives there and only URLs leave.
final class SpotlightSearch: @unchecked Sendable {
    private let query: SearchQuery
    private let stopLock = NSLock()
    private var stopHandler: (@MainActor () -> Void)?
    init(query: SearchQuery) { self.query = query }

    func updates() async -> AsyncStream<[URL]> {
        let query = query
        let stream = AsyncStream<[URL]>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            Task { @MainActor [weak self] in
                let driver = SpotlightDriver(query: query) { continuation.yield($0) }
                guard driver.start() else { continuation.finish(); return }
                self?.setStop { driver.stop(); continuation.finish() }
            }
        }
        return stream
    }
    @MainActor func stop() {
        stopLock.lock(); let handler = stopHandler; stopHandler = nil; stopLock.unlock()
        handler?()
    }
    private func setStop(_ handler: @escaping @MainActor () -> Void) {
        stopLock.lock(); stopHandler = handler; stopLock.unlock()
    }
}

@MainActor private final class SpotlightDriver: NSObject {
    private let metadata = NSMetadataQuery()
    private let deliver: ([URL]) -> Void
    private let limit: Int
    private let keepsAlive: [NSObjectProtocol] = []
    private var observers: [NSObjectProtocol] = []

    init(query: SearchQuery, deliver: @escaping ([URL]) -> Void) {
        self.deliver = deliver
        self.limit = max(query.limit * 3, 450)
        super.init()
        // The text is bound as a value, never interpolated into the predicate's syntax.
        metadata.predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*\(query.text)*")
        switch query.scope {
        case .currentFolder(let url): metadata.searchScopes = [url.path]
        case .home, .userFolders: metadata.searchScopes = [NSMetadataQueryUserHomeScope]
        case .thisMac, .computer, .recents: metadata.searchScopes = [NSMetadataQueryLocalComputerScope]
        case .trash(let roots): metadata.searchScopes = roots.map(\.path)
        }
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: metadata, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.publish() }
            })
        }
    }
    func start() -> Bool { metadata.start() }
    func stop() {
        metadata.stop()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
    private func publish() {
        metadata.disableUpdates()
        var urls: [URL] = []
        let count = min(metadata.resultCount, limit)
        for index in 0..<count {
            if let item = metadata.result(at: index) as? NSMetadataItem,
               let path = item.value(forAttribute: NSMetadataItemPathKey) as? String {
                urls.append(URL(fileURLWithPath: path))
            }
        }
        metadata.enableUpdates()
        deliver(urls)
    }
}
#endif
