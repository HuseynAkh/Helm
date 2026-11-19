import Foundation
import HelmCore

/// Metadata-only candidate; adapters supply document conformance without file-content reads (F-045).
public struct SearchCandidate: Sendable, Equatable {
    public let entry: FileEntry
    public let relativeDepth: Int?
    public let isDocumentLike: Bool
    public init(entry: FileEntry, relativeDepth: Int? = nil, isDocumentLike: Bool = false) {
        self.entry = entry; self.relativeDepth = relativeDepth; self.isDocumentLike = isDocumentLike
    }
}
/// Immutable ranking context preserves root casing and avoids Home enumeration (B-026).
public struct SearchRankingContext: Sendable {
    public let query: HelmCore.SearchQuery
    public let preferredRoots: [URL]
    public let includeSystemLocations: Bool
    /// AI search's folder to measure from: the nearer an item is to it, the higher it ranks (`proximityBonus`), and
    /// every candidate is scored, none dropped by date first. Plain search leaves it out and keeps the frozen weights.
    public let proximityRoot: URL?
    /// AI search's own words from the request (`SearchRanker.requestWords`): each that starts a word of an item's
    /// name adds `requestWordBonus`, so what the person typed counts, not only the words a model planned.
    public let requestWords: [String]
    public init(query: HelmCore.SearchQuery, preferredRoots: [URL]? = nil, includeSystemLocations: Bool = false,
                proximityRoot: URL? = nil, requestWords: [String] = []) {
        self.query = query; self.includeSystemLocations = includeSystemLocations
        self.preferredRoots = preferredRoots ?? PreferredRoots.standard(home: query.homeDirectory)
        self.proximityRoot = proximityRoot; self.requestWords = requestWords
    }
}
/// Frozen F-045 weights; stored ordinal relevance fixes B-022, deterministic final path fixes ties.
public enum SearchRanker {
    public enum NameMatch: Sendable { case exact, prefix, wordBoundary, substring, none }
    public static func nameMatch(_ name: String, query: String) -> NameMatch {
        let name = folded(name); let query = folded(query)
        guard !query.isEmpty else { return .none }
        if name == query { return .exact }
        if name.hasPrefix(query) { return .prefix }
        if name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(query) }) { return .wordBoundary }
        return name.contains(query) ? .substring : .none
    }
    private static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    public static func hardCap(limit: Int) -> Int {
        let product = max(0, limit).multipliedReportingOverflow(by: 3)
        return product.overflow ? Int.max : max(product.partialValue, 450)
    }
    static func contains(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
    public static func score(_ candidate: SearchCandidate, context: SearchRankingContext, now: Date) -> Int {
        let entry = candidate.entry; let query = folded(context.query.text.trimmingCharacters(in: .whitespacesAndNewlines))
        let path = entry.url.standardizedFileURL.path.lowercased(); let home = context.query.homeDirectory.standardizedFileURL.path.lowercased()
        var total: Int
        switch nameMatch(entry.name, query: query) {
        case .exact: total = 1200
        case .prefix: total = 800
        case .wordBoundary, .substring: total = 500 // Distinct classification; frozen legacy score.
        case .none: total = 0
        }
        for token in query.split(whereSeparator: \.isWhitespace) where folded(entry.name).contains(token) { total += 100 }
        if context.preferredRoots.contains(where: { contains(path, root: $0.standardizedFileURL.path.lowercased()) }) {
            let depth = max(0, candidate.relativeDepth ?? (path.split(separator: "/").count - home.split(separator: "/").count - 1))
            total += 380 + max(0, 150 - min(depth, 5) * 30)
        } else if contains(path, root: home) && !path.hasPrefix(home + "/library/") { total += 220 }
        if context.query.bookmarkPaths.contains(where: { contains(path, root: URL(fileURLWithPath: $0).standardizedFileURL.path.lowercased()) }) { total += 300 }
        if let active = context.query.lastDirectory, path.hasPrefix(active.standardizedFileURL.path.lowercased() + "/") { total += 200 }
        if entry.isDirectoryLike { total += 80 }
        if documentLike(candidate) { total += 140 }
        if entry.isHidden { total -= 280 }
        if !context.includeSystemLocations && ["system", "library", "private", "usr", "bin", "sbin", "dev", "opt"].contains(where: { path.hasPrefix("/" + $0 + "/") }) { total -= 650 }
        let age = now.timeIntervalSince(entry.modificationDate)
        if age < 86400 { total += 90 } else if age < 604800 { total += 55 } else if age < 2592000 { total += 25 }
        if case .currentFolder = context.query.scope { total += 40 }
        if let root = context.proximityRoot, let depth = depth(ofPath: path, below: root) { total += proximityBonus(depth: depth) }
        if !context.requestWords.isEmpty {
            let words = folded(entry.name).split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            for word in context.requestWords where words.contains(where: { $0.hasPrefix(word) }) { total += requestWordBonus }
        }
        return total
    }

    /// What nearness to AI search's folder adds: 250 for an item right in it, 50 less for each folder further down,
    /// nothing from five folders down. It stays below the smallest step between two kinds of name match (exact 1200,
    /// prefix 800, inside a word 500), so a near file comes before a deep one that matches as well, and a deep file
    /// whose name matches better still comes first, as VS Code's and fzf's scorers keep depth below match quality.
    public static func proximityBonus(depth: Int) -> Int { max(0, 5 - max(0, depth)) * 50 }
    /// A listing with no words to rank by, such as a kind chosen with nothing typed: what's right in `root` first,
    /// then a folder down, and so on, newest first at each depth and by name after that; anything outside `root`
    /// last, newest first. Each item once, `limit` at most.
    public static func nearestFirst(_ candidates: [SearchCandidate], below root: URL, limit: Int) -> [SearchResult] {
        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0.entry.url.standardizedFileURL.path).inserted }
        let depths = unique.map { depth(of: $0.entry.url, below: root) ?? Int.max }
        let ordered = zip(unique, depths).sorted { left, right in
            if left.1 != right.1 { return left.1 < right.1 }
            if left.0.entry.modificationDate != right.0.entry.modificationDate {
                return left.0.entry.modificationDate > right.0.entry.modificationDate
            }
            return tieLess(left.0.entry, right.0.entry)
        }
        return ordered.prefix(max(0, limit)).enumerated().map {
            SearchResult(entry: $0.element.0.entry, rank: $0.offset, isDocumentLike: documentLike($0.element.0))
        }
    }
    /// What one of the request's own words adds when it starts a word of the name.
    public static let requestWordBonus = 150
    /// How many folders below `root` an item is: 0 for an item right in it, nil for one outside it or the folder itself.
    public static func depth(of url: URL, below root: URL) -> Int? {
        depth(ofPath: url.standardizedFileURL.path.lowercased(), below: root)
    }
    static func depth(ofPath path: String, below root: URL) -> Int? {
        let rootPath = root.standardizedFileURL.path.lowercased()
        guard path != rootPath, contains(path, root: rootPath) else { return nil }
        return path.split(separator: "/").count - rootPath.split(separator: "/").count - 1
    }
    /// The words of a request that can name a file: folded, three letters or more, each once, without the words
    /// that only shape a sentence ("the", "my", "find") or name a kind the kind row already covers ("photos").
    public static func requestWords(_ request: String) -> [String] {
        var seen: Set<String> = []
        return folded(request).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 3 && !sentenceWords.contains($0) && seen.insert($0).inserted }
    }
    private static let sentenceWords: Set<String> = [
        "the", "and", "for", "with", "from", "that", "this", "these", "those", "what", "where", "which", "when", "who",
        "about", "into", "onto", "some", "any", "all", "our", "your", "their", "his", "her", "its", "mine", "find",
        "show", "get", "give", "look", "looking", "search", "want", "need", "was", "were", "are", "has", "had", "have",
        "can", "could", "one", "ones", "thing", "things", "somewhere", "something", "anything", "not", "but", "then",
        "than", "there", "here", "out", "off", "over", "under", "just", "also", "like", "kind", "sort", "file", "files",
        "folder", "folders", "photo", "photos", "picture", "pictures", "pic", "pics", "image", "images", "video",
        "videos", "movie", "movies", "clip", "clips", "document", "documents", "doc", "docs", "pdf", "pdfs",
    ]
    public static func documentLike(_ candidate: SearchCandidate) -> Bool {
        candidate.isDocumentLike || Set(["txt", "md", "rtf", "pdf", "doc", "docx", "odt", "pages", "xls", "xlsx", "numbers", "ppt", "pptx", "key", "csv", "json", "yaml", "yml", "xml"]).contains(candidate.entry.url.pathExtension.lowercased())
    }
    public static func rank(_ candidates: [SearchCandidate], context: SearchRankingContext, clock: any HelmClock = SystemHelmClock(), upstreamTruncated: Bool = false) -> SearchRankedBatch {
        let cap = hardCap(limit: context.query.limit); let now = clock.now()
        // Spotlight's pre-cap order, legacy lines 52–55 and 197–198.
        let ordered = candidates.sorted { a, b in
            if a.entry.modificationDate != b.entry.modificationDate { return a.entry.modificationDate > b.entry.modificationDate }
            return tieLess(a.entry, b.entry)
        }
        var seen = Set<String>()
        // AI search scores every candidate: a cap by date first would drop the near, older ones it ranks up.
        let measured = context.proximityRoot != nil
        let bounded = (measured ? ordered[...] : ordered.prefix(cap)).filter { seen.insert($0.entry.url.standardizedFileURL.path).inserted }
        let scored = bounded.map { ($0, score($0, context: context, now: now)) }.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.entry.modificationDate != b.0.entry.modificationDate { return a.0.entry.modificationDate > b.0.entry.modificationDate }
            return tieLess(a.0.entry, b.0.entry)
        }
        let limit = max(0, context.query.limit)
        let results = scored.prefix(limit).enumerated().map { SearchResult(entry: $0.element.0.entry, rank: $0.offset, isDocumentLike: documentLike($0.element.0)) }
        let capped = upstreamTruncated || (!measured && candidates.count > cap)
        return SearchRankedBatch(results: results, truncated: capped || scored.count > limit, candidateLimitReached: capped, consideredCount: bounded.count)
    }
    private static func tieLess(_ a: FileEntry, _ b: FileEntry) -> Bool {
        let order = a.name.compare(b.name, options: [.numeric, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if order != .orderedSame { return order == .orderedAscending }
        return a.url.standardizedFileURL.path < b.url.standardizedFileURL.path
    }
}
