// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Symbolic scopes avoid turning computer scope into a path (F-043, B-024).
public enum SearchDomain: Sendable, Equatable, Codable {
    case currentFolder(URL), home, thisMac, recents
}
/// Portable metadata comparisons for advanced filename search (F-044).
public enum SearchClause: Sendable, Equatable, Codable {
    case name(String), kind(FileEntryKind), ext(String), before(Date), after(Date)
    case sizeLessThan(Int64), sizeGreaterThan(Int64), tag(String)
}
/// Local wrapper until Core SearchQuery gains advanced filters and symbolic scopes (F-043).
public struct SearchRequest: Sendable, Equatable, Codable {
    public var text: String
    public var scope: SearchDomain
    public var filters: [SearchClause]
    public var includeHidden: Bool
    public init(text: String, scope: SearchDomain = .home, filters: [SearchClause] = [], includeHidden: Bool = false) {
        self.text = text; self.scope = scope; self.filters = filters; self.includeHidden = includeHidden
    }
}
/// Predicate DATA only: adapters must bind literal strings, never interpolate syntax (F-044).
public struct SearchSpecification: Sendable, Equatable, Codable {
    public let scope: SearchDomain
    public let clauses: [SearchClause]
    public let includeHidden: Bool
    public init(scope: SearchDomain, clauses: [SearchClause], includeHidden: Bool) {
        self.scope = scope; self.clauses = clauses; self.includeHidden = includeHidden
    }
    public var rankingText: String { clauses.compactMap { if case .name(let text) = $0 { return text }; return nil }.joined(separator: " ") }
    public var requiresTags: Bool { clauses.contains { if case .tag = $0 { return true }; return false } }
    public func matches(_ entry: FileEntry, tags: Set<String> = []) -> Bool {
        guard includeHidden || (!entry.isHidden && !entry.name.hasPrefix(".")) else { return false }
        return clauses.allSatisfy { clause in
            switch clause {
            case .name(let text): return entry.name.range(of: text, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")) != nil
            case .kind(let kind): return entry.kind == kind
            case .ext(let ext): return entry.url.pathExtension.lowercased() == ext.lowercased()
            case .before(let date): return entry.modificationDate < date
            case .after(let date): return entry.modificationDate >= date
            case .sizeLessThan(let size): return entry.size < size
            case .sizeGreaterThan(let size): return entry.size > size
            case .tag(let tag): return tags.contains(tag)
            }
        }
    }
}
