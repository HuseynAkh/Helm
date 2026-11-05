import Foundation
import HelmCore

/// Directory drops add sorted bookmarks; loading never filters unmounted paths (F-028, B-029).
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
    @discardableResult public func add(_ url: URL, isDirectory: Bool, at date: Date = Date()) -> Bool {
        guard url.isFileURL, isDirectory else { return false }
        let path = url.standardizedFileURL.path
        guard !records.contains(where: { $0.path == path }) else { return false }
        let record = BookmarkRecord(path: path, name: Self.displayName(path: path, home: home), addedAt: date)
        file.replace(with: Self.sorted(records + [record])); return true
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
