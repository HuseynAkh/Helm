// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
import HelmFileSystem

/// Fallback is deliberate: empty Spotlight results alone never prove absent indexing (F-046).
public enum SearchFallbackPolicy {
    public static func shouldEnumerate(spotlightAvailable: Bool, knownUnindexed: Bool, userRequested: Bool) -> Bool {
        !spotlightAvailable || knownUnindexed || userRequested
    }
}
/// Bounded metadata walk avoids packages, symlinks and file-content reads (F-044, B-026).
public struct EnumerationSearchService: Sendable {
    private let fileSystem: any FileSystem
    private let clock: any HelmClock
    public init(fileSystem: any FileSystem, clock: any HelmClock = SystemHelmClock()) { self.fileSystem = fileSystem; self.clock = clock }
    public func search(_ specification: SearchSpecification, roots: [URL], context: SearchRankingContext, maxDepth: Int = 16, visitLimit: Int = 10000) async throws -> SearchRankedBatch {
        try Task.checkCancellation()
        if specification.requiresTags { throw EnumerationSearchError.tagsUnavailable }
        if case .recents = specification.scope { throw EnumerationSearchError.recentsRequireMetadataSource }
        let allowed: [URL]
        switch specification.scope {
        case .currentFolder(let root): allowed = [root]
        case .home, .userFolders: allowed = [context.query.homeDirectory]
        case .thisMac, .computer: allowed = roots // Explicit roots only; never invent broad filesystem scopes.
        case .trash(let directories): allowed = directories
        case .recents: allowed = []
        }
        var pending = allowed.map { ($0.standardizedFileURL, 0) }; var seen = Set<String>()
        var candidates: [SearchCandidate] = []; var visited = 0; var truncated = false
        walk: while let (directory, depth) = pending.popLast() {
            try Task.checkCancellation()
            guard seen.insert(directory.path).inserted else { continue }
            for try await batch in fileSystem.enumerate(directory, options: EnumerationOptions(includeHidden: specification.includeHidden, resolveSymlinkTargets: false)) {
                try Task.checkCancellation()
                for entry in batch {
                    try Task.checkCancellation()
                    guard visited < max(0, visitLimit) else { truncated = true; break walk }
                    visited += 1
                    guard specification.includeHidden || (!entry.isHidden && !entry.name.hasPrefix(".")) else { continue }
                    if specification.matches(entry) { candidates.append(SearchCandidate(entry: entry)) }
                    if entry.kind == .directory {
                        if depth < max(0, maxDepth) { pending.append((entry.url, depth + 1)) }
                        else { truncated = true }
                    }
                }
            }
        }
        try Task.checkCancellation()
        return SearchRanker.rank(candidates, context: context, clock: clock, upstreamTruncated: truncated)
    }
}
/// Unsupported metadata never silently broadens an enumeration query (F-044).
public enum EnumerationSearchError: Error, Equatable { case tagsUnavailable, recentsRequireMetadataSource }
