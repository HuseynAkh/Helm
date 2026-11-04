import Foundation
import HelmCore
import HelmPersistence

@MainActor final class MemoryDefaults: KeyValueStoring, LegacyDefaultsReading {
    var values: [String: Any] = [:]
    var registered: [String: Any] = [:]
    var domains: [String: [String: Any]] = [:]
    func object(forKey key: String) -> Any? { values[key] ?? registered[key] }
    func set(_ value: Any, forKey key: String) { values[key] = value }
    func register(defaults: [String: Any]) { registered.merge(defaults) { old, _ in old } }
    func data(forKey key: String, domain: String?) -> Data? {
        if let domain { return domains[domain]?[key] as? Data }
        return values[key] as? Data
    }
    func hasStoredSetting(for key: SettingKey, domain: String) -> Bool {
        domains[domain]?[key.rawValue] != nil
    }
    func storedSetting(for key: SettingKey, domain: String) -> SettingValue? {
        domains[domain]?[key.rawValue] as? SettingValue
    }
}

func temporaryStoreDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("Helm-K4-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
