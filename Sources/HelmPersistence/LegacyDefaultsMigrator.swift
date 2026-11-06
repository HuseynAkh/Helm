import Foundation
import HelmCore

/// Explicit domain reads prevent registered defaults masking absent legacy settings (F-065, B-029).
@MainActor public protocol LegacyDefaultsReading {
    func data(forKey key: String, domain: String?) -> Data?
    func storedSetting(for key: SettingKey, domain: String) -> SettingValue?
    func hasStoredSetting(for key: SettingKey, domain: String) -> Bool
}

/// Read-only access to standard and persistent development/bundle domains (F-028–F-030).
@MainActor public final class LegacyUserDefaultsReader: LegacyDefaultsReading {
    private let defaults: UserDefaults
    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func data(forKey key: String, domain: String?) -> Data? {
        if let domain { return defaults.persistentDomain(forName: domain)?[key] as? Data }
        return defaults.data(forKey: key)
    }
    public func hasStoredSetting(for key: SettingKey, domain: String) -> Bool {
        defaults.persistentDomain(forName: domain)?[key.rawValue] != nil
    }
    public func storedSetting(for key: SettingKey, domain: String) -> SettingValue? {
        SettingsStore.value(defaults.persistentDomain(forName: domain)?[key.rawValue], key: key)
    }
}

/// A legacy key that can't be read. The others have migrated; this one stays untouched and is retried next launch.
public struct LegacyMigrationIncomplete: Error, Equatable {
    public let keys: [String]
    public init(keys: [String]) { self.keys = keys }
}

/// Once-only, idempotent migration leaves every legacy key untouched (F-028–F-030, B-029).
/// Each key migrates on its own, so one damaged key can't cost the other collections (FB2-9).
/// Anything left unread or unwritten leaves the flag unset and can be safely retried.
@MainActor public final class LegacyDefaultsMigrator {
    public static let doneKey: String = "helm.migration.v1.done"
    public let changes: Broadcast<Bool> = Broadcast()
    private let reader: any LegacyDefaultsReading
    private let destination: any KeyValueStoring
    private let directory: URL
    private let home: URL
    private let bundleDomain: String
    private var reported: Bool = false
    private let report: (String) -> Void
    public init(reader: any LegacyDefaultsReading, destination: any KeyValueStoring, directory: URL,
                home: URL, bundleDomain: String = "com.helm.filemanager", report: @escaping (String) -> Void = { _ in }) {
        self.reader = reader; self.destination = destination; self.directory = directory
        self.home = home; self.bundleDomain = bundleDomain; self.report = report
    }
    @discardableResult public func migrate(at date: Date = Date()) async throws -> Bool {
        guard (destination.object(forKey: Self.doneKey) as? Bool) != true else { return false }
        do { try await perform(at: date) }
        catch {
            if !reported { report(String(describing: error)); reported = true }
            throw error
        }
        destination.set(true, forKey: Self.doneKey); changes.send(true); return true
    }
    private func perform(at date: Date) async throws {
        var starURLs: [URL] = []
        var bookmarkURLs: [URL] = []
        var recents: [RecentRecord] = []
        var malformed: [String] = []
        func read<Value: Decodable>(_ key: String, domain: String?, as type: Value.Type) -> Value? {
            guard let data = reader.data(forKey: key, domain: domain) else { return nil }
            do { return try JSONDecoder().decode(type, from: data) }
            catch {
                if !malformed.contains(key) { malformed.append(key) }
                return nil
            }
        }
        for domain: String? in [nil, bundleDomain, "Helm"] {
            starURLs += read("com.helm.starredFiles", domain: domain, as: [URL].self) ?? []
            bookmarkURLs += read("helm.bookmarks", domain: domain, as: [URL].self) ?? []
            recents += read("helm.recentAccessRecords", domain: domain, as: [RecentRecord].self) ?? []
        }
        let stars = JSONFileStore<[StarRecord]>(url: directory.appendingPathComponent("stars.json"), empty: [])
        let bookmarks = JSONFileStore<[BookmarkRecord]>(url: directory.appendingPathComponent("bookmarks.json"), empty: [])
        let recent = JSONFileStore<[RecentRecord]>(url: directory.appendingPathComponent("recent.json"), empty: [])
        try await stars.load(recoverCorruption: false)
        try await bookmarks.load(recoverCorruption: false)
        try await recent.load(recoverCorruption: false)
        var starPaths = Set(stars.items.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        var mergedStars = stars.items
        for url in starURLs where url.isFileURL {
            let path = url.standardizedFileURL.path
            if starPaths.insert(path).inserted { mergedStars.append(StarRecord(path: path, addedAt: date)) }
        }
        var bookmarkPaths = Set(bookmarks.items.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
        var mergedBookmarks = bookmarks.items
        for url in bookmarkURLs where url.isFileURL {
            let path = url.standardizedFileURL.path
            if bookmarkPaths.insert(path).inserted {
                mergedBookmarks.append(BookmarkRecord(path: path, name: BookmarkStore.displayName(path: path, home: home), addedAt: date))
            }
        }
        stars.replace(with: mergedStars.sorted { $0.path < $1.path })
        bookmarks.replace(with: BookmarkStore.sorted(mergedBookmarks))
        recent.replace(with: RecentStore.merged(recent.items + recents))
        try await stars.flush(); try await bookmarks.flush(); try await recent.flush()
        // Verification also rejects unsupported schemas; no completion flag until all three decode.
        try await stars.load(recoverCorruption: false)
        try await bookmarks.load(recoverCorruption: false)
        try await recent.load(recoverCorruption: false)
        for key in SettingKey.allCases {
            let sourceDomain = reader.hasStoredSetting(for: key, domain: bundleDomain) ? bundleDomain : "Helm"
            let value = reader.storedSetting(for: key, domain: sourceDomain)
            if let value { destination.set(SettingsStore.object(SettingsSchema.validated(value, for: key)), forKey: key.rawValue) }
        }
        if !malformed.isEmpty { throw LegacyMigrationIncomplete(keys: malformed) }
    }
}
