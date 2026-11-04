import Foundation

/// Search scope is explicit: current folder, user folders, computer, or trash (F-043).
public enum SearchScope: Hashable, Sendable, Codable { case currentFolder(URL), userFolders, computer, trash([URL]) }
/// Immutable inputs preserve bookmark ranking without reading defaults in the search module (F-044).
public struct SearchQuery: Sendable, Equatable {
    public var text: String
    public var scope: SearchScope
    public var bookmarkPaths: [String]
    public var homeDirectory: URL
    public var lastDirectory: URL?
    public var showHidden: Bool
    public var limit: Int
    public init(text: String, scope: SearchScope, bookmarkPaths: [String], homeDirectory: URL,
                lastDirectory: URL?, showHidden: Bool, limit: Int) {
        self.text = text; self.scope = scope; self.bookmarkPaths = bookmarkPaths
        self.homeDirectory = homeDirectory; self.lastDirectory = lastDirectory
        self.showHidden = showHidden; self.limit = limit
    }
}
/// Ranked metadata preserves search ordering (F-044); smaller ordinal ranks indicate stronger matches.
public struct SearchResult: Hashable, Sendable {
    public let entry: FileEntry
    public let rank: Int
    public let isDocumentLike: Bool
    public init(entry: FileEntry, rank: Int, isDocumentLike: Bool = false) {
        self.entry = entry; self.rank = rank; self.isDocumentLike = isDocumentLike
    }
}
/// Per-tab search overlay carries request identity to reject stale results (F-043, B-021).
/// Conservative state: query, generation, results and gathering flag; navigation remains separate.
public struct SearchState: Sendable, Equatable {
    public var query: SearchQuery
    public var generation: Generation
    public var results: [SearchResult]
    public var isGathering: Bool
    public init(query: SearchQuery, generation: Generation = Generation(), results: [SearchResult] = [], isGathering: Bool = true) {
        self.query = query; self.generation = generation; self.results = results; self.isGathering = isGathering
    }
}
/// Search lifecycle keeps incremental results separate from indexing availability (F-046).
public enum SearchEvent: Sendable, Equatable { case gathering, results([SearchResult], isFinal: Bool), notIndexed }
/// Portable service boundary for Spotlight and enumeration fallback (F-046).
public protocol SearchService: Sendable { func search(_ query: SearchQuery) -> AsyncThrowingStream<SearchEvent, Error> }
