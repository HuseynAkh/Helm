import Foundation

/// Symbolic scopes preserve Home/computer/Recents intent; legacy case spellings remain decodable (F-043).
public enum SearchScope: Hashable, Sendable, Codable { case currentFolder(URL), home, thisMac, recents, userFolders, computer, trash([URL]) }
/// Immutable inputs preserve bookmark ranking without reading defaults in the search module (F-044).
public struct SearchQuery: Sendable, Equatable {
    public var text: String
    public var scope: SearchScope
    public var bookmarkPaths: [String]
    public var homeDirectory: URL
    public var lastDirectory: URL?
    public var showHidden: Bool
    public var filters: [SearchClause]
    public var limit: Int
    /// Also match what's inside documents, through Spotlight's content index, as Finder does.
    public var includesContents: Bool
    /// The person asked a model to help with this search. The words are still their own.
    public var usesAI: Bool
    /// Only items of this kind, as the AI search's kind row chose it, or of a kind it covers (`AISearchKind.covers`).
    /// Nil for any kind, as every search is while the row isn't on show.
    public var kind: AISearchKind?
    public init(text: String, scope: SearchScope, bookmarkPaths: [String], homeDirectory: URL,
                lastDirectory: URL?, showHidden: Bool, limit: Int, filters: [SearchClause] = [], includesContents: Bool = false,
                usesAI: Bool = false, kind: AISearchKind? = nil) {
        self.text = text; self.scope = scope; self.bookmarkPaths = bookmarkPaths
        self.homeDirectory = homeDirectory; self.lastDirectory = lastDirectory
        self.showHidden = showHidden; self.limit = limit; self.filters = filters
        self.includesContents = includesContents; self.usesAI = usesAI; self.kind = kind
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
    /// What a model added to this search: where it has got to, and why each result matched. Nil for a plain search.
    public var assist: SearchAssist?
    public init(query: SearchQuery, generation: Generation = Generation(), results: [SearchResult] = [], isGathering: Bool = true,
                assist: SearchAssist? = nil) {
        self.query = query; self.generation = generation; self.results = results; self.isGathering = isGathering
        self.assist = assist
    }
}
/// Search lifecycle keeps incremental results separate from indexing availability (F-046).
public enum SearchEvent: Sendable, Equatable { case gathering, results(SearchRankedBatch, isFinal: Bool), notIndexed }
/// Portable service boundary for Spotlight and enumeration fallback (F-046).
public protocol SearchService: Sendable { func search(_ query: SearchQuery) -> AsyncThrowingStream<SearchEvent, Error> }
