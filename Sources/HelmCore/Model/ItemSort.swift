import Foundation

/// Preserves stored sort fields and natural names (F-040), with strict ordering for equal values.
/// Localized collation can vary between Linux ICU and macOS; raw paths break ties deterministically.
public struct ItemSort: Hashable, Sendable, Codable {
    /// `lastOpened` is Recent's own order; items with no date sort as the oldest.
    public enum Field: String, CaseIterable, Sendable, Codable { case name, size, dateModified, kind, relevance, lastOpened }
    public let field: Field
    public let ascending: Bool
    public let directoriesFirst: Bool
    public init(field: Field = .name, ascending: Bool = true, directoriesFirst: Bool = true) {
        self.field = field; self.ascending = ascending; self.directoriesFirst = directoriesFirst
    }
    public static let defaultSort: ItemSort = ItemSort()
    /// Search ranks use smaller numbers for better results and do not group directories.
    public static let relevance: ItemSort = ItemSort(field: .relevance, directoriesFirst: false)
    public func toggling(field newField: Field) -> ItemSort {
        ItemSort(field: newField, ascending: field == newField ? !ascending : true, directoriesFirst: directoriesFirst)
    }
    public func compare(_ a: FileEntry, _ b: FileEntry, rankByID: [ItemID: Int] = [:]) -> Bool {
        if directoriesFirst && a.isDirectoryLike != b.isDirectoryLike { return a.isDirectoryLike }
        let order: ComparisonResult
        switch field {
        case .name: order = a.name.localizedStandardCompare(b.name)
        case .kind: order = (a.localizedKindDescription ?? "").localizedStandardCompare(b.localizedKindDescription ?? "")
        case .size: order = Self.order(a.size, b.size)
        case .dateModified: order = Self.order(a.modificationDate, b.modificationDate)
        case .relevance: order = Self.order(rankByID[a.id] ?? Int.max, rankByID[b.id] ?? Int.max)
        case .lastOpened:
            order = Self.order(a.lastOpenedDate ?? .distantPast, b.lastOpenedDate ?? .distantPast)
            // Items with the same date, or none (the files inside a folder opened in Recent's list), read A to Z
            // whichever way the dates run, as a folder lists them, rather than in reverse path order.
            if order == .orderedSame { return Self.byName(a, b) }
        }
        let resolved: ComparisonResult
        if order == .orderedSame { resolved = Self.order(a.id.rawValue, b.id.rawValue) } else { resolved = order }
        return resolved == (ascending ? .orderedAscending : .orderedDescending)
    }
    public func sorted(_ items: [FileEntry], rankByID: [ItemID: Int] = [:]) -> [FileEntry] {
        items.sorted { compare($0, $1, rankByID: rankByID) }
    }
    private static func order<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult {
        a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }
    /// Natural name order, A to Z, with the path settling exact ties.
    private static func byName(_ a: FileEntry, _ b: FileEntry) -> Bool {
        let names = a.name.localizedStandardCompare(b.name)
        return (names == .orderedSame ? order(a.id.rawValue, b.id.rawValue) : names) == .orderedAscending
    }

    private enum CodingKeys: String, CodingKey { case field, ascending, directoriesFirst, exactField }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let stored = try values.decode(Field.self, forKey: .field)
        // A field from a newer build than this one is skipped in favour of the stand-in written beside it.
        let exact = try? values.decodeIfPresent(Field.self, forKey: .exactField)
        self.init(field: exact ?? stored, ascending: try values.decode(Bool.self, forKey: .ascending),
                  directoriesFirst: try values.decode(Bool.self, forKey: .directoriesFirst))
    }
    /// Builds from before Last Opened can't read it, and would set aside a whole saved session or the folders' view
    /// options over it. So it's written as the nearest order they know, Modified in the same direction, with the
    /// real field beside it. Every other sort is written exactly as before.
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(field == .lastOpened ? Field.dateModified : field, forKey: .field)
        try values.encode(ascending, forKey: .ascending)
        try values.encode(directoriesFirst, forKey: .directoriesFirst)
        if field == .lastOpened { try values.encode(field, forKey: .exactField) }
    }
}
