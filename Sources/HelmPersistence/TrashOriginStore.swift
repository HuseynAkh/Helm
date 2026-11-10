import Foundation
import HelmCore

/// Only Helm-recorded trash destinations enable Put Back (F-060); no guessed Finder origins.
public struct TrashOriginRecord: Codable, Equatable, Sendable {
    public let trashedPath: String
    public let originalPath: String
    public let trashedAt: Date
    public init(trashedPath: String, originalPath: String, trashedAt: Date) {
        self.trashedPath = trashedPath; self.originalPath = originalPath; self.trashedAt = trashedAt
    }
}

/// Known trash origins persist across launches through the core dependency seam (F-060).
/// A record is kept only while its item is in the Trash, and at most `limit` are carried into the next launch.
@MainActor public final class TrashOriginStore: TrashOriginRecording {
    /// The most records kept when Helm starts. Past it, the oldest go first. None goes while Helm runs: Undo of a
    /// Move to Trash needs the record of every item it moved.
    public static let limit = 1_000
    private let file: JSONFileStore<[TrashOriginRecord]>
    public var records: [TrashOriginRecord] { file.items }
    public let changes: Broadcast<[TrashOriginRecord]>
    public var lastError: (any Error)? { file.lastError }
    public init(url: URL) async throws {
        file = JSONFileStore(url: url, empty: [])
        changes = file.changes
        try await file.load()
        if file.items.count > Self.limit { file.replace(with: Self.capped(file.items)) }
    }
    public func record(_ items: [TrashedItem]) async {
        record(items, at: Date())
    }
    public func record(_ items: [TrashedItem], at date: Date) {
        file.replace(with: Self.adding(items, at: date, to: records))
    }
    public func originalURL(forTrashed url: URL) async -> URL? {
        Self.original(of: url, in: records)
    }
    /// Forgets where these items came from, once they've left the Trash.
    public func removeOrigins(for urls: [URL]) {
        let kept = Self.removing(urls, from: records)
        if kept.count != records.count { file.replace(with: kept) }
    }
    public func flush() async throws { try await file.flush() }

    /// One spelling for a place in the Trash, whether or not the item is still there. `standardizedFileURL` turns
    /// /private/tmp/x into /tmp/x only while x exists, so without this a record made in the Trash wouldn't match
    /// the same place once the item had left it.
    public static func place(_ url: URL) -> String { place(ofPath: url.standardizedFileURL.path) }
    public static func place(ofPath path: String) -> String {
        for root in ["/private/tmp/", "/private/var/", "/private/etc/"] where path.hasPrefix(root) {
            return String(path.dropFirst("/private".count))
        }
        return path
    }
    /// Where the item at this place in the Trash came from, if Helm put it there.
    public static func original(of url: URL, in records: [TrashOriginRecord]) -> URL? {
        guard url.isFileURL else { return nil }
        let key = place(url)
        return records.first { place(ofPath: $0.trashedPath) == key }.map { URL(fileURLWithPath: $0.originalPath) }
    }
    /// `records` with these items added, each replacing any older record for the same place in the Trash.
    /// Nothing is dropped for room here: that happens only when Helm starts.
    public static func adding(_ items: [TrashedItem], at date: Date, to records: [TrashOriginRecord]) -> [TrashOriginRecord] {
        var result = records
        for item in items where item.trashedURL.isFileURL && item.originalURL.isFileURL {
            let key = place(item.trashedURL)
            result.removeAll { place(ofPath: $0.trashedPath) == key }
            result.append(TrashOriginRecord(trashedPath: key,
                originalPath: item.originalURL.standardizedFileURL.path, trashedAt: date))
        }
        return result.sorted { $0.trashedPath < $1.trashedPath }
    }
    /// `records` without those for these places in the Trash.
    public static func removing(_ urls: [URL], from records: [TrashOriginRecord]) -> [TrashOriginRecord] {
        let keys = Set(urls.filter(\.isFileURL).map(place))
        return records.filter { !keys.contains(place(ofPath: $0.trashedPath)) }
    }
    /// The newest `limit` records, in path order.
    static func capped(_ records: [TrashOriginRecord]) -> [TrashOriginRecord] {
        let newest = records.count <= limit ? records : Array(records.sorted {
            $0.trashedAt == $1.trashedAt ? $0.trashedPath < $1.trashedPath : $0.trashedAt > $1.trashedAt
        }.prefix(limit))
        return newest.sorted { $0.trashedPath < $1.trashedPath }
    }
}
