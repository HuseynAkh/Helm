// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation

/// Available list metadata; defaults preserve F-036's four columns.
public enum ListColumn: String, CaseIterable, Hashable, Sendable, Codable {
    case name, size, dateModified, kind, dateCreated, dateLastOpened, dateAdded, version, comments, tags, location
}

/// Grouping is independent of sorting (F-040 extended by M18).
public enum GroupBy: String, Sendable, Codable { case none, kind, dateModified, size, tag }

/// Per-folder preferences preserve grid/list and sort defaults (F-036, F-040, F-065).
/// Missing fields use defaults; future schema versions are rejected for safe retention by persistence.
public struct ViewOptions: Equatable, Sendable, Codable {
    public static let schemaVersion: Int = 1
    public let viewMode: ViewMode
    public let sort: ItemSort
    public let groupBy: GroupBy
    public let iconSize: Double
    public let showColumns: Set<ListColumn>
    public let textSize: Double
    public init(viewMode: ViewMode = .grid, sort: ItemSort = .defaultSort, groupBy: GroupBy = .none,
                iconSize: Double = 96, showColumns: Set<ListColumn> = [.name, .size, .dateModified, .kind],
                textSize: Double = 12) {
        self.viewMode = viewMode; self.sort = sort; self.groupBy = groupBy
        self.iconSize = iconSize.isFinite ? min(512, max(16, iconSize)) : 96
        self.showColumns = showColumns.union([.name])
        self.textSize = textSize.isFinite ? min(32, max(9, textSize)) : 12
    }
    private enum CodingKeys: String, CodingKey {
        case version, viewMode, sort, groupBy, iconSize, showColumns, textSize
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard version == Self.schemaVersion else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: values, debugDescription: "Unsupported view options schema")
        }
        self.init(viewMode: try values.decodeIfPresent(ViewMode.self, forKey: .viewMode) ?? .grid,
                  sort: try values.decodeIfPresent(ItemSort.self, forKey: .sort) ?? .defaultSort,
                  groupBy: try values.decodeIfPresent(GroupBy.self, forKey: .groupBy) ?? .none,
                  iconSize: try values.decodeIfPresent(Double.self, forKey: .iconSize) ?? 96,
                  showColumns: try values.decodeIfPresent(Set<ListColumn>.self, forKey: .showColumns) ?? [.name, .size, .dateModified, .kind],
                  textSize: try values.decodeIfPresent(Double.self, forKey: .textSize) ?? 12)
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.schemaVersion, forKey: .version)
        try values.encode(viewMode, forKey: .viewMode); try values.encode(sort, forKey: .sort)
        try values.encode(groupBy, forKey: .groupBy); try values.encode(iconSize, forKey: .iconSize)
        try values.encode(showColumns, forKey: .showColumns); try values.encode(textSize, forKey: .textSize)
    }
}

/// Injectable portable serialization; persistence owns disk access (F-065, M24).
public protocol ViewOptionsSerialization: Sendable {
    func encode(_ value: ViewOptions) throws -> Data
    func decode(_ data: Data) throws -> ViewOptions
}

/// Versioned JSON implementation for folder options (F-065).
public struct JSONViewOptionsSerialization: ViewOptionsSerialization {
    public init() {}
    public func encode(_ value: ViewOptions) throws -> Data { try JSONEncoder().encode(value) }
    public func decode(_ data: Data) throws -> ViewOptions { try JSONDecoder().decode(ViewOptions.self, from: data) }
}
