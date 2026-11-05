// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Definition identity is separate from result paths; Finder predicates stay opaque (F-043, F-044).
public struct SavedSearchOpenPlan: Sendable {
    /// Helm definitions are editable; Finder predicates remain opaque data (F-043).
    public enum Content: Sendable {
        case editable(SavedSearchDocument)
        case opaque(FinderSavedSearchDocument)
        case rejected(String)
    }
    public let definitionURL: URL
    public let content: Content
    public init(definitionURL: URL, data: Data) {
        self.definitionURL = definitionURL
        guard LocalFileURLAdmission.accepts(definitionURL) else {
            content = .rejected("Definition must be a local file URL"); return
        }
        if let document = try? SavedSearchCodec.decode(data) {
            content = .editable(document)
        } else if let document = try? FinderSavedSearchCodec.decode(data) {
            content = .opaque(document)
        } else { content = .rejected("Malformed or unsupported search definition") }
    }
    /// Empty definitions may be edited, but never imply a match-everything search (F-043).
    public var searchRequest: SearchRequest? {
        guard case .editable(let document) = content,
              let specification = try? SearchQueryParser.compile(document.request),
              !specification.clauses.isEmpty else { return nil }
        return document.request
    }
    /// Value-only intent for a separately approved host operation; contains no result-file URLs.
    public var definitionRemovalIntent: URL? {
        guard LocalFileURLAdmission.accepts(definitionURL) else { return nil }
        return definitionURL
    }
}
