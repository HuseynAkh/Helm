import Foundation

actor RecentItemsService {

    static let shared = RecentItemsService()

    private struct Record: Codable {
        let path: String
        var lastAccessedAt: Date
    }

    private static let storageKey = "helm.recentAccessRecords"
    private let maxRecordCount = 300
    private let defaults: UserDefaults
    private var records: [Record] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.records = Self.loadRecords(from: defaults)
    }

    func recordAccess(to url: URL) {
        guard url.isFileURL else { return }

        let standardized = url.standardizedFileURL.path
        guard !standardized.isEmpty else { return }

        records.removeAll { $0.path == standardized }
        records.insert(Record(path: standardized, lastAccessedAt: Date()), at: 0)

        if records.count > maxRecordCount {
            records = Array(records.prefix(maxRecordCount))
        }
        save()
    }

    func recentURLs(limit: Int = 120) -> [URL] {
        pruneMissingEntries()
        guard !records.isEmpty else { return [] }
        return records
            .prefix(max(0, limit))
            .map { URL(fileURLWithPath: $0.path) }
    }

    func recentItems(limit: Int = 120, starredService: StarredFilesService? = nil) -> [FileItem] {
        let urls = recentURLs(limit: limit)
        guard !urls.isEmpty else { return [] }

        var items: [FileItem] = []
        items.reserveCapacity(urls.count)
        for url in urls {
            if let item = try? FileItem.from(url: url, starredService: starredService) {
                items.append(item)
            }
        }
        return items
    }

    func clear() {
        records.removeAll()
        defaults.removeObject(forKey: Self.storageKey)
    }

    private static func loadRecords(from defaults: UserDefaults) -> [Record] {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([Record].self, from: data) else {
            return []
        }
        return decoded.sorted { $0.lastAccessedAt > $1.lastAccessedAt }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private func pruneMissingEntries() {
        let fm = FileManager.default
        let beforeCount = records.count
        records.removeAll { !fm.fileExists(atPath: $0.path) }
        if records.count != beforeCount {
            save()
        }
    }
}
