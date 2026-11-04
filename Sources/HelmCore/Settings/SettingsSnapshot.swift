import Foundation

/// Immutable, validated preferences for reducers and services (F-065, B-059).
public struct SettingsSnapshot: Sendable, Equatable, Codable {
    public let values: [String: SettingValue]
    public init(values: [String: SettingValue] = [:]) {
        self.values = Dictionary(uniqueKeysWithValues: SettingKey.allCases.map {
            ($0.rawValue, SettingsSchema.validated(values[$0.rawValue], for: $0))
        })
    }
    public init(reader: any SettingsReading) {
        self.init(values: Dictionary(uniqueKeysWithValues: SettingKey.allCases.map {
            ($0.rawValue, SettingsSchema.validated(reader.value(for: $0), for: $0))
        }))
    }
    public subscript(_ key: SettingKey) -> SettingValue {
        values[key.rawValue] ?? SettingsSchema.defaultValue(for: key)
    }
    public func bool(_ key: SettingKey) -> Bool {
        if case .bool(let value) = self[key] { return value }; return false
    }
    public func integer(_ key: SettingKey) -> Int {
        if case .integer(let value) = self[key] { return value }; return 0
    }
    public func double(_ key: SettingKey) -> Double {
        if case .double(let value) = self[key] { return value }; return 0
    }
    public func string(_ key: SettingKey) -> String {
        if case .string(let value) = self[key] { return value }; return ""
    }
    public var showHiddenFiles: Bool { bool(.showHiddenFiles) }
    public var defaultViewMode: ViewMode { ViewMode(rawValue: string(.defaultViewMode)) ?? .grid }
    public var defaultSort: ItemSort {
        ItemSort(field: ItemSort.Field(rawValue: string(.defaultSortField)) ?? .name,
                 ascending: bool(.defaultSortAscending), directoriesFirst: bool(.directoriesFirst))
    }
    private enum CodingKeys: String, CodingKey { case values }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(values: try container.decode([String: SettingValue].self, forKey: .values))
    }
}
