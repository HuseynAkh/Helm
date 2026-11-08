// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
import HelmPersistence

// Internal fakes never touch UserDefaults or schedule disk writes (B-068).
@MainActor final class AppMemorySettings: KeyValueStoring {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any, forKey key: String) { values[key] = value }
    func register(defaults: [String: Any]) { values.merge(defaults) { old, _ in old } }
}
@MainActor final class AppMemoryBookmarks: AppBookmarkStoring {
    private(set) var records: [BookmarkRecord] = []
    let changes = Broadcast<[BookmarkRecord]>()
    let home: URL
    init(home: URL) { self.home = home.standardizedFileURL }
    func add(_ url: URL, isDirectory: Bool, at date: Date) -> Bool {
        insert(url, isDirectory: isDirectory, at: records.count, date: date)
    }
    func insert(_ url: URL, isDirectory: Bool, at index: Int, date: Date) -> Bool {
        guard url.isFileURL, isDirectory else { return false }
        let url = url.standardizedFileURL
        guard !records.contains(where: { $0.path == url.path }) else { return false }
        records.insert(BookmarkRecord(path: url.path, name: url == home ? "Home" : (url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent), addedAt: date),
                       at: min(max(0, index), records.count))
        changes.send(records); return true
    }
    func move(path: String, to index: Int) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let from = records.firstIndex(where: { $0.path == normalized }) else { return }
        records = BookmarkOrder.moved(records, from: from, to: index); changes.send(records)
    }
    func remove(path: String) {
        records.removeAll { $0.path == URL(fileURLWithPath: path).standardizedFileURL.path }; changes.send(records)
    }
    func flush() async throws {}
}
@MainActor final class AppMemoryStars: AppStarStoring {
    private(set) var records: [StarRecord] = []
    let changes = Broadcast<[StarRecord]>()
    func isStarred(_ url: URL) -> Bool { url.isFileURL && records.contains { $0.path == url.standardizedFileURL.path } }
    func star(_ url: URL, at date: Date) {
        guard url.isFileURL, !isStarred(url) else { return }
        records.append(StarRecord(path: url.standardizedFileURL.path, addedAt: date))
        records.sort { $0.path < $1.path }; changes.send(records)
    }
    func unstar(_ url: URL) {
        guard url.isFileURL else { return }
        records.removeAll { $0.path == url.standardizedFileURL.path }; changes.send(records)
    }
    func flush() async throws {}
}
@MainActor final class AppMemoryRecents: AppRecentStoring {
    private(set) var records: [RecentRecord] = []
    let changes = Broadcast<[RecentRecord]>()
    func recordAccess(to url: URL, kind: FileEntryKind, at date: Date) {
        guard url.isFileURL else { return }
        let path = url.standardizedFileURL.path
        if let old = records.first(where: { $0.path == path }), old.lastAccessedAt >= date { return }
        records.removeAll { $0.path == path }
        records.append(RecentRecord(path: path, lastAccessedAt: date, kind: kind))
        records.sort { $0.lastAccessedAt == $1.lastAccessedAt ? $0.path < $1.path : $0.lastAccessedAt > $1.lastAccessedAt }
        records = Array(records.prefix(RecentStore.storedLimit)); changes.send(records)
    }
    func recentRecords() async -> [RecentRecord] { Array(records.prefix(RecentStore.displayedLimit)) }
    func clear() { records = []; changes.send(records) }
    func flush() async throws {}
}
@MainActor final class AppMemorySession: AppSessionStoring {
    private(set) var windows: [SessionWindow] = []
    let changes = Broadcast<[SessionWindow]>()
    func replace(windows: [SessionWindow]) { self.windows = windows; changes.send(windows) }
    func flush() async throws {}
}
@MainActor final class AppMemoryTrashOrigins: AppTrashOriginStoring {
    private var origins: [URL: URL] = [:]
    func record(_ items: [TrashedItem]) async {
        for item in items where item.trashedURL.isFileURL && item.originalURL.isFileURL {
            origins[item.trashedURL.standardizedFileURL] = item.originalURL.standardizedFileURL
        }
    }
    func originalURL(forTrashed url: URL) async -> URL? {
        guard url.isFileURL else { return nil }
        return origins[url.standardizedFileURL]
    }
    func flush() async throws {}
}
