import Foundation
import HelmCore

/// Virtual sources do not invent writable directory targets (B-031).
public protocol LocationSource: Sendable {
    func load(_ location: Location, options: LoadOptions) -> AsyncThrowingStream<LoadEvent, Error>
    func monitor(_ location: Location) -> (any DirectoryMonitor)?
}
/// Snapshot materialization sorts off the UI actor; cache hits require access validation (F-035, B-009).
public struct DirectoryLoader: LocationSource {
    private let fileSystem: any FileSystem
    private let cache: ListingCache
    public init(fileSystem: any FileSystem, cache: ListingCache = ListingCache()) {
        self.fileSystem = fileSystem; self.cache = cache
    }
    public func load(_ location: Location, options: LoadOptions = LoadOptions()) -> AsyncThrowingStream<LoadEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard case .directory(let url) = location else { throw FileSystemError.unsupported }
                    let root = try await fileSystem.entry(at: url)
                    guard root.isReadable else { throw FileSystemError.permissionDenied }
                    guard root.isDirectoryLike || root.kind == .package else { throw FileSystemError.other("Not a directory") }
                    // Validate open permission even when metadata and cache are available.
                    var entries: [FileEntry] = []
                    for try await batch in fileSystem.enumerate(url, options: EnumerationOptions(
                        includeHidden: options.showHidden, batchSize: options.batchSize)) {
                        try Task.checkCancellation()
                        entries.append(contentsOf: batch)
                        continuation.yield(.batch(batch))
                    }
                    if options.useCache {
                        await cache.store(entries, for: location, showHidden: options.showHidden, token: root.changeToken)
                    }
                    continuation.yield(.finished); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    /// Snapshot materialization keeps natural sorting independent of filesystem iteration order (F-040).
    public func snapshot(_ location: Location, options: LoadOptions = LoadOptions()) async throws -> [FileEntry] {
        try Task.checkCancellation()
        if options.useCache, case .directory(let url) = location {
            let root = try await fileSystem.entry(at: url)
            guard root.isReadable else { throw FileSystemError.permissionDenied }
            if let cached = await cache.entries(for: location, showHidden: options.showHidden, token: root.changeToken) {
                // Opening an iterator validates directory access even if metadata is cached.
                var validation = fileSystem.enumerate(url, options: EnumerationOptions(
                    includeHidden: options.showHidden, batchSize: 1)).makeAsyncIterator()
                _ = try await validation.next()
                try Task.checkCancellation()
                return options.sort.sorted(cached)
            }
        }
        var entries: [FileEntry] = []
        for try await event in load(location, options: options) {
            if case .batch(let values) = event { entries.append(contentsOf: values) }
        }
        return options.sort.sorted(entries)
    }
    /// Parent changes reconcile the full listing; direct-child changes only stat affected entries (B-073).
    public func refresh(location: Location, changed: Set<String>, current: [FileEntry],
                        options: LoadOptions = LoadOptions()) async throws -> [FileEntry] {
        guard case .directory(let directory) = location else { throw FileSystemError.unsupported }
        await cache.invalidate(location)
        if changed.contains(directory.standardizedFileURL.path) { return try await snapshot(location, options: options) }
        var byID = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        for path in changed {
            try Task.checkCancellation()
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.deletingLastPathComponent().path == directory.standardizedFileURL.path else { continue }
            do {
                let value = try await fileSystem.entry(at: url)
                if options.showHidden || !value.isHidden { byID[value.id] = value }
                else { byID.removeValue(forKey: value.id) }
            } catch {
                guard FileSystemError.mapping(error) == .notFound else { throw error }
                byID.removeValue(forKey: ItemID(url: url))
            }
        }
        return options.sort.sorted(Array(byID.values))
    }
    public func monitor(_ location: Location) -> (any DirectoryMonitor)? {
        guard case .directory(let url) = location else { return nil }
        return fileSystem.makeMonitor(for: url)
    }
}
