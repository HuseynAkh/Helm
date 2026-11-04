// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore

/// Versioned Helm search data extends F-043 without persisting executable predicates.
public struct SavedSearchDocument: Sendable, Equatable, Codable {
    public let version: Int
    public var name: String
    public var request: SearchRequest
    public init(name: String, request: SearchRequest, version: Int = 1) { self.version = version; self.name = name; self.request = request }
}
/// Malformed/future documents and unsupported edits are explicit (F-043, M23).
public enum SavedSearchError: Error, Equatable { case unsupportedVersion(Int), malformed, readOnly }
/// In-memory codecs only; the caller owns any approved file writes (F-043, M23).
public enum SavedSearchCodec {
    public static func encode(_ document: SavedSearchDocument) throws -> Data {
        guard document.version == 1 else { throw SavedSearchError.unsupportedVersion(document.version) }
        _ = try SearchQueryParser.compile(document.request)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }
    public static func decode(_ data: Data) throws -> SavedSearchDocument {
        guard data.count <= 1_048_576 else { throw SavedSearchError.malformed }
        let document = try JSONDecoder().decode(SavedSearchDocument.self, from: data)
        guard document.version == 1 else { throw SavedSearchError.unsupportedVersion(document.version) }
        _ = try SearchQueryParser.compile(document.request)
        return document
    }
}
/// Conservative Finder subset retains original bytes, including unknown keys (F-043, M23).
/// RawQuery stays opaque and must never be executed or interpreted by this portable module.
public struct FinderSavedSearchDocument: Sendable {
    public let rawQuery: String
    public let searchScopes: [String]
    public let readOnlyReasons: [String]
    public var isReadOnly: Bool { !readOnlyReasons.isEmpty }
    fileprivate let original: Data
    public init(rawQuery: String, searchScopes: [String]) throws {
        guard searchScopes.allSatisfy({ $0.hasPrefix("/") }) else { throw SavedSearchError.malformed }
        self.rawQuery = rawQuery; self.searchScopes = searchScopes; self.readOnlyReasons = []
        self.original = try PropertyListSerialization.data(fromPropertyList: ["RawQuery": rawQuery, "SearchCriteria": ["FXScopeArrayOfPaths": searchScopes]], format: .xml, options: 0)
    }
    fileprivate init(rawQuery: String, searchScopes: [String], reasons: [String], original: Data) {
        self.rawQuery = rawQuery; self.searchScopes = searchScopes; self.readOnlyReasons = reasons; self.original = original
    }
}
/// Finder interchange supports RawQuery and SearchCriteria/FXScopeArrayOfPaths only (M23).
public enum FinderSavedSearchCodec {
    public static func decode(_ data: Data) throws -> FinderSavedSearchDocument {
        guard data.count <= 1_048_576,
              let dictionary = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let raw = dictionary["RawQuery"] as? String,
              let criteria = dictionary["SearchCriteria"] as? [String: Any],
              let scopes = criteria["FXScopeArrayOfPaths"] as? [String] else { throw SavedSearchError.malformed }
        var reasons = dictionary.keys.filter { !["RawQuery", "SearchCriteria"].contains($0) }.sorted().map { "Unsupported Finder key: \($0)" }
        reasons += criteria.keys.filter { $0 != "FXScopeArrayOfPaths" }.sorted().map { "Unsupported criterion: \($0)" }
        if scopes.contains(where: { !$0.hasPrefix("/") }) { reasons.append("Unsupported symbolic Finder scope") }
        return FinderSavedSearchDocument(rawQuery: raw, searchScopes: scopes, reasons: reasons, original: data)
    }
    public static func encode(_ document: FinderSavedSearchDocument) -> Data { document.original }
    public static func replacing(_ document: FinderSavedSearchDocument, rawQuery: String, searchScopes: [String]) throws -> FinderSavedSearchDocument {
        guard !document.isReadOnly else { throw SavedSearchError.readOnly }
        guard searchScopes.allSatisfy({ $0.hasPrefix("/") }) else { throw SavedSearchError.malformed }
        return try FinderSavedSearchDocument(rawQuery: rawQuery, searchScopes: searchScopes)
    }
}
