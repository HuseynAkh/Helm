// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Typed AND rows compile to the same data clauses as filename tokens (F-043, F-044).
public enum SearchCriteriaRow: Sendable, Equatable {
    case nameContains(String), kind(FileEntryKind), modifiedBefore(Date), modifiedOnOrAfter(Date)
    case sizeLessThan(Int64), sizeGreaterThan(Int64), tag(String), fileExtension(String)
    public var clause: SearchClause {
        switch self {
        case .nameContains(let value): return .name(value)
        case .kind(let value): return .kind(value)
        case .modifiedBefore(let value): return .before(value)
        case .modifiedOnOrAfter(let value): return .after(value)
        case .sizeLessThan(let value): return .sizeLessThan(value)
        case .sizeGreaterThan(let value): return .sizeGreaterThan(value)
        case .tag(let value): return .tag(value)
        case .fileExtension(let value): return .ext(value)
        }
    }
    public init(clause: SearchClause) {
        switch clause {
        case .name(let value): self = .nameContains(value)
        case .kind(let value): self = .kind(value)
        case .before(let value): self = .modifiedBefore(value)
        case .after(let value): self = .modifiedOnOrAfter(value)
        case .sizeLessThan(let value): self = .sizeLessThan(value)
        case .sizeGreaterThan(let value): self = .sizeGreaterThan(value)
        case .tag(let value): self = .tag(value)
        case .ext(let value): self = .fileExtension(value)
        }
    }
}
/// Safe row edits report stale indices without traps (F-043).
public enum SearchCriteriaError: Error, Equatable { case invalidIndex }
/// Editing preserves the original text, scope and hidden policy; Finder RawQuery stays opaque (F-043).
public struct SearchCriteriaEditor: Sendable {
    public private(set) var rows: [SearchCriteriaRow]
    private var document: SavedSearchDocument?
    public let opaqueDocument: FinderSavedSearchDocument?
    public var isReadOnly: Bool { opaqueDocument != nil }
    public init(document: SavedSearchDocument) {
        self.document = document; self.rows = document.request.filters.map(SearchCriteriaRow.init); self.opaqueDocument = nil
    }
    public init(opaqueDocument: FinderSavedSearchDocument) {
        self.document = nil; self.rows = []; self.opaqueDocument = opaqueDocument
    }
    public mutating func append(_ row: SearchCriteriaRow) throws {
        guard !isReadOnly else { throw SavedSearchError.readOnly }
        rows.append(row)
    }
    public mutating func replace(at index: Int, with row: SearchCriteriaRow) throws {
        guard !isReadOnly else { throw SavedSearchError.readOnly }
        guard rows.indices.contains(index) else { throw SearchCriteriaError.invalidIndex }
        rows[index] = row
    }
    public mutating func remove(at index: Int) throws {
        guard !isReadOnly else { throw SavedSearchError.readOnly }
        guard rows.indices.contains(index) else { throw SearchCriteriaError.invalidIndex }
        rows.remove(at: index)
    }
    public func savedDocument() throws -> SavedSearchDocument {
        guard var value = document else { throw SavedSearchError.readOnly }
        value.request.filters = rows.map(\.clause)
        _ = try SearchQueryParser.compile(value.request)
        return value
    }
    public func encode() throws -> Data {
        if let opaqueDocument { return FinderSavedSearchCodec.encode(opaqueDocument) }
        return try SavedSearchCodec.encode(savedDocument())
    }
}
