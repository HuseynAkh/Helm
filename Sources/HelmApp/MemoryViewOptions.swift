// DRAFT: pending review, 2026-11-05
import Foundation
import HelmCore
import HelmPersistence

// In-memory counterpart of LocationViewOptionsStore; reads retain its LRU behavior (F-036, F-040, B-068).
@MainActor final class AppMemoryViewOptions: AppViewOptionsStoring {
    let isReadOnly = false
    let recoveryBackupURL: URL? = nil
    private(set) var defaults = ViewOptions()
    private var records: [(key: String, options: ViewOptions)] = []
    private let capacity: Int = 256

    func options(for location: Location) -> ViewOptions {
        let key = LocationViewOptionsStore.stableKey(for: location)
        guard let index = records.firstIndex(where: { $0.key == key }) else { return defaults }
        let record = records.remove(at: index)
        records.append(record)
        return record.options
    }
    func hasOptions(for location: Location) -> Bool {
        let key = LocationViewOptionsStore.stableKey(for: location)
        return records.contains { $0.key == key }
    }
    func set(_ options: ViewOptions, for location: Location) throws {
        let key = LocationViewOptionsStore.stableKey(for: location)
        records.removeAll { $0.key == key }
        records.append((key: key, options: options))
        if records.count > capacity { records.removeFirst(records.count - capacity) }
    }
    func useAsDefaults(_ options: ViewOptions) throws { defaults = options }
    func useAsDefaults(for location: Location) throws { defaults = options(for: location) }
    func removeRecords(forVanishedLocations locations: [Location]) throws {
        let keys = Set(locations.map(LocationViewOptionsStore.stableKey))
        records.removeAll { keys.contains($0.key) }
    }
    func flush() async throws {}
}
