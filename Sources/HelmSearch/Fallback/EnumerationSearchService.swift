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
/// Compatibility adapter delegates to the bounded engine (F-044, B-026).
/// Both entry points share diagnostics, cancellation, scope admission and traversal policy.
public struct EnumerationSearchService: Sendable {
    private let fileSystem: any FileSystem
    private let clock: any HelmClock
    public init(fileSystem: any FileSystem, clock: any HelmClock = SystemHelmClock()) { self.fileSystem = fileSystem; self.clock = clock }
    public func search(_ specification: SearchSpecification, roots: [URL], context: SearchRankingContext,
                       maxDepth: Int = 16, visitLimit: Int = 10000,
                       diagnostic: @Sendable (SearchDiagnostic) -> Void = { _ in }) async throws -> SearchRankedBatch {
        let request = SearchRequest(text: "", scope: specification.scope, filters: specification.clauses,
                                    includeHidden: specification.includeHidden)
        let resolver = SearchRootResolver(home: context.query.homeDirectory, computerRoots: roots)
        let engine = SearchEngine(fileSystem: fileSystem, resolver: resolver, clock: clock)
        return try await engine.collect(request, context: context,
            options: SearchWalkOptions(maxDepth: maxDepth, visitLimit: visitLimit), diagnostic: diagnostic)
    }
}
/// Unsupported metadata never silently broadens an enumeration query (F-044).
public enum EnumerationSearchError: Error, Equatable { case tagsUnavailable, recentsRequireMetadataSource }
