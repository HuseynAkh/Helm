// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
import HelmFileSystem

/// Explicit roots preserve symbolic scope intent without widening searches (F-043, B-099).
public protocol SearchScopeResolving: Sendable {
    func roots(for scope: SearchScope) async throws -> [URL]
}
/// Composition-root supplied locations; Recents requires metadata (F-043).
public struct SearchRootResolver: SearchScopeResolving {
    public let home: URL
    public let computerRoots: [URL]
    public init(home: URL, computerRoots: [URL] = []) { self.home = home; self.computerRoots = computerRoots }
    public func roots(for scope: SearchScope) async throws -> [URL] {
        switch scope {
        case .currentFolder(let root): return [root]
        case .home, .userFolders: return [home]
        case .thisMac, .computer: return computerRoots
        case .trash(let roots): return roots
        case .recents: throw EnumerationSearchError.recentsRequireMetadataSource
        }
    }
}
/// Partial reads and terminal failures remain visible to presentation (F-046, B-099).
public enum SearchDiagnostic: Sendable, Equatable {
    case unreadable(URL), failed(String), cancelled
}
/// Explicit bounded traversal never follows links or reads contents (F-044, B-026).
public struct SearchWalkOptions: Sendable {
    public let maxDepth: Int
    public let visitLimit: Int
    public let includePackageContents: Bool
    public init(maxDepth: Int = 16, visitLimit: Int = 10000, includePackageContents: Bool = false) {
        self.maxDepth = max(0, maxDepth); self.visitLimit = max(0, visitLimit)
        self.includePackageContents = includePackageContents
    }
}
/// Stable ranked snapshots preserve F-045 weights and expose incomplete walks (B-026).
/// Enumeration is sequential, each directory sorted by path before applying the visit budget.
public struct SearchEngine: Sendable {
    private let fileSystem: any FileSystem
    private let resolver: any SearchScopeResolving
    private let clock: any HelmClock
    public init(fileSystem: any FileSystem, resolver: any SearchScopeResolving, clock: any HelmClock = SystemHelmClock()) {
        self.fileSystem = fileSystem; self.resolver = resolver; self.clock = clock
    }
    public func collect(_ request: SearchRequest, context: SearchRankingContext,
                        options: SearchWalkOptions = SearchWalkOptions(),
                        diagnostic: @Sendable (SearchDiagnostic) -> Void = { _ in }) async throws -> SearchRankedBatch {
        let walk = try await candidates(request, options: options, diagnostic: diagnostic)
        try Task.checkCancellation()
        return SearchRanker.rank(walk.values, context: rankingContext(request, context), clock: clock, upstreamTruncated: walk.truncated)
    }
    /// Cumulative snapshots are emitted only after global ranking, so batch timing cannot reorder results.
    /// Cancelling the consumer cancels this stream's worker and its current filesystem stream (B-021).
    public func search(_ request: SearchRequest, context: SearchRankingContext, batchSize: Int = 128,
                       options: SearchWalkOptions = SearchWalkOptions(),
                       diagnostic: @escaping @Sendable (SearchDiagnostic) -> Void = { _ in }) -> AsyncStream<SearchRankedBatch> {
        AsyncStream { continuation in
            let task = Task {
                do {
                    let result = try await collect(request, context: context, options: options, diagnostic: diagnostic)
                    let size = max(1, batchSize)
                    var end = 0
                    repeat {
                        try Task.checkCancellation()
                        end += min(size, result.results.count - end)
                        continuation.yield(SearchRankedBatch(results: Array(result.results.prefix(end)), truncated: result.truncated,
                            candidateLimitReached: result.candidateLimitReached, consideredCount: result.consideredCount))
                    } while end < result.results.count
                } catch is CancellationError { diagnostic(.cancelled) }
                catch { diagnostic(.failed(String(describing: error))) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func metadataRoots(for scope: SearchScope) async throws -> [URL]? {
        if scope == .recents { return nil }
        return try await resolver.roots(for: scope).map { $0.standardizedFileURL }
    }
    func rankingContext(_ request: SearchRequest, _ context: SearchRankingContext) -> SearchRankingContext {
        var query = context.query
        query.text = (try? SearchQueryParser.compile(request).rankingText) ?? ""
        query.scope = request.scope; query.showHidden = request.includeHidden; query.filters = request.filters
        return SearchRankingContext(query: query, preferredRoots: context.preferredRoots, includeSystemLocations: context.includeSystemLocations)
    }
    func candidates(_ request: SearchRequest, options: SearchWalkOptions,
                    diagnostic: @Sendable (SearchDiagnostic) -> Void) async throws -> (values: [SearchCandidate], truncated: Bool) {
        try Task.checkCancellation()
        let specification = try SearchQueryParser.compile(request)
        guard !specification.requiresTags else { throw EnumerationSearchError.tagsUnavailable }
        let roots = try await resolver.roots(for: request.scope)
        var pending = Array(Set(roots.map { $0.standardizedFileURL })).sorted { $0.path > $1.path }.map { ($0, 0) }
        var seen = Set<String>(); var visited = Set<String>(); var values: [SearchCandidate] = []; var truncated = false
        walk: while let (directory, depth) = pending.popLast() {
            try Task.checkCancellation()
            guard seen.insert(directory.path).inserted else { continue }
            do {
                let rootEntry = try await fileSystem.entry(at: directory)
                guard rootEntry.kind == .directory || (rootEntry.kind == .package && options.includePackageContents) else { continue }
                var entries: [FileEntry] = []
                for try await batch in fileSystem.enumerate(directory, options: EnumerationOptions(includeHidden: request.includeHidden, resolveSymlinkTargets: false)) {
                    try Task.checkCancellation()
                    entries.append(contentsOf: batch)
                }
                try Task.checkCancellation()
                for entry in entries.sorted(by: { $0.url.standardizedFileURL.path < $1.url.standardizedFileURL.path }) {
                    try Task.checkCancellation()
                    let path = entry.url.standardizedFileURL.path
                    // Ignore malformed adapters that return non-children or duplicate entries.
                    guard entry.url.standardizedFileURL.deletingLastPathComponent().path == directory.path,
                          !visited.contains(path), request.includeHidden || (!entry.isHidden && !entry.name.hasPrefix(".")) else { continue }
                    guard visited.count < options.visitLimit else { truncated = true; break walk }
                    visited.insert(path)
                    if specification.matches(entry) { values.append(SearchCandidate(entry: entry)) }
                    if entry.kind == .directory || (entry.kind == .package && options.includePackageContents) {
                        if !entry.isReadable { diagnostic(.unreadable(entry.url)); truncated = true }
                        else if depth < options.maxDepth { pending.append((entry.url.standardizedFileURL, depth + 1)) }
                        else { truncated = true }
                    }
                }
            } catch {
                try Task.checkCancellation()
                if FileSystemError.mapping(error) == .permissionDenied { diagnostic(.unreadable(directory)); truncated = true }
                else { throw error }
            }
        }
        try Task.checkCancellation()
        return (values, truncated)
    }
}
