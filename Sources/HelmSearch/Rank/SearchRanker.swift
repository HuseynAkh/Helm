// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
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
    public init(query: HelmCore.SearchQuery, preferredRoots: [URL]? = nil, includeSystemLocations: Bool = false) {
        self.query = query; self.includeSystemLocations = includeSystemLocations
        self.preferredRoots = preferredRoots ?? PreferredRoots.standard(home: query.homeDirectory)
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
        return total
    }
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
        let bounded = ordered.prefix(cap).filter { seen.insert($0.entry.url.standardizedFileURL.path).inserted }
        let scored = bounded.map { ($0, score($0, context: context, now: now)) }.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            if a.0.entry.modificationDate != b.0.entry.modificationDate { return a.0.entry.modificationDate > b.0.entry.modificationDate }
            return tieLess(a.0.entry, b.0.entry)
        }
        let limit = max(0, context.query.limit)
        let results = scored.prefix(limit).enumerated().map { SearchResult(entry: $0.element.0.entry, rank: $0.offset, isDocumentLike: documentLike($0.element.0)) }
        let capped = upstreamTruncated || candidates.count > cap
        return SearchRankedBatch(results: results, truncated: capped || scored.count > limit, candidateLimitReached: capped, consideredCount: bounded.count)
    }
    private static func tieLess(_ a: FileEntry, _ b: FileEntry) -> Bool {
        let order = a.name.compare(b.name, options: [.numeric, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        if order != .orderedSame { return order == .orderedAscending }
        return a.url.standardizedFileURL.path < b.url.standardizedFileURL.path
    }
}
