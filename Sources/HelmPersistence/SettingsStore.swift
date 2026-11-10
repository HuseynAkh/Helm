import Foundation
import HelmCore

/// Injected persistence keeps tests out of real defaults and preserves exact keys (F-065).
@MainActor public protocol KeyValueStoring: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any, forKey key: String)
    func register(defaults: [String: Any])
}

/// Foundation adapter is available on Linux and macOS (F-065).
@MainActor public final class UserDefaultsAdapter: KeyValueStoring {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func object(forKey key: String) -> Any? { defaults.object(forKey: key) }
    public func set(_ value: Any, forKey key: String) { defaults.set(value, forKey: key) }
    public func register(defaults values: [String: Any]) { defaults.register(defaults: values) }
}

/// The only settings writer publishes validated immutable snapshots (F-065, B-059).
@MainActor public final class SettingsStore {
    public private(set) var snapshot: SettingsSnapshot
    public let changes: Broadcast<SettingsSnapshot> = Broadcast()
    private let storage: any KeyValueStoring
    public init(storage: any KeyValueStoring) {
        self.storage = storage
        storage.register(defaults: Dictionary(uniqueKeysWithValues: SettingKey.allCases.map {
            ($0.rawValue, Self.object(SettingsSchema.defaultValue(for: $0)))
        }))
        self.snapshot = Self.read(storage)
    }
    public func set(_ value: SettingValue, for key: SettingKey) {
        let validated = SettingsSchema.validated(value, for: key)
        storage.set(Self.object(validated), forKey: key.rawValue)
        let next = Self.read(storage)
        guard next != snapshot else { return }
        snapshot = next; changes.send(next)
    }
    static func object(_ value: SettingValue) -> Any {
        switch value {
        case .bool(let v): return v
        case .integer(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        }
    }
    static func value(_ object: Any?, key: SettingKey) -> SettingValue? {
        guard let object else { return nil }
        switch SettingsSchema.defaultValue(for: key) {
        case .string: return (object as? String).map(SettingValue.string)
        case .bool:
            guard let number = object as? NSNumber, String(cString: number.objCType) == "c" else { return nil }
            return .bool(number.boolValue)
        case .integer:
            guard let number = object as? NSNumber,
                  !["c", "f", "d"].contains(String(cString: number.objCType)) else { return nil }
            return .integer(number.intValue)
        case .double:
            guard let number = object as? NSNumber, String(cString: number.objCType) != "c" else { return nil }
            return .double(number.doubleValue)
        }
    }
    private static func read(_ storage: any KeyValueStoring) -> SettingsSnapshot {
        let values = Dictionary(uniqueKeysWithValues: SettingKey.allCases.map {
            ($0.rawValue, SettingsSchema.validated(value(storage.object(forKey: $0.rawValue), key: $0), for: $0))
        })
        return SettingsSnapshot(values: values)
    }
}
