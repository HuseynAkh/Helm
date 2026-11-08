import Foundation
import HelmCore

/// Bookmarks keep the order you give them; loading never filters unmounted paths (F-028, B-029, P-188).
@MainActor public final class BookmarkStore {
    private let file: JSONFileStore<[BookmarkRecord]>
    private let home: URL
    public var records: [BookmarkRecord] { file.items }
    public let changes: Broadcast<[BookmarkRecord]>
    public var lastError: (any Error)? { file.lastError }
    public init(url: URL, home: URL) async throws {
        self.home = home.standardizedFileURL
        file = JSONFileStore(url: url, empty: [])
        changes = file.changes
        try await file.load()
    }
    /// New bookmarks go at the end, as in Finder and Nautilus. They stay in the order you put them.
    @discardableResult public func add(_ url: URL, isDirectory: Bool, at date: Date = Date()) -> Bool {
        insert(url, isDirectory: isDirectory, at: records.count, date: date)
    }
    @discardableResult public func insert(_ url: URL, isDirectory: Bool, at index: Int, date: Date = Date()) -> Bool {
        guard url.isFileURL, isDirectory else { return false }
        let path = url.standardizedFileURL.path
        guard !records.contains(where: { $0.path == path }) else { return false }
        var next = records
        next.insert(BookmarkRecord(path: path, name: Self.displayName(path: path, home: home), addedAt: date), at: min(max(0, index), next.count))
        file.replace(with: next); return true
    }
    public func move(path: String, to index: Int) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let from = records.firstIndex(where: { $0.path == normalized }) else { return }
        let next = BookmarkOrder.moved(records, from: from, to: index)
        if next.map(\.path) != records.map(\.path) { file.replace(with: next) }
    }
    public func remove(path: String) {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        file.replace(with: records.filter { $0.path != normalized })
    }
    public func flush() async throws { try await file.flush() }
    static func displayName(path: String, home: URL) -> String {
        if path == home.standardizedFileURL.path { return "Home" }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
    static func sorted(_ records: [BookmarkRecord]) -> [BookmarkRecord] {
        records.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.path < $1.path : order == .orderedAscending
        }
    }
}
