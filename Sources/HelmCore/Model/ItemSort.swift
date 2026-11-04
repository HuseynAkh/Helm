import Foundation

/// Preserves stored sort fields and natural names (F-040), with strict ordering for equal values.
/// Localized collation can vary between Linux ICU and macOS; raw paths break ties deterministically.
public struct ItemSort: Hashable, Sendable, Codable {
    public enum Field: String, CaseIterable, Sendable, Codable { case name, size, dateModified, kind, relevance }
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
}
