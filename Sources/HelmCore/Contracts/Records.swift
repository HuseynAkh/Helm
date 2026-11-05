import Foundation

/// Legacy Recent JSON uses path and lastAccessedAt (F-030); retains the existing date coding strategy.
public struct RecentRecord: Hashable, Sendable, Codable {
    public let path: String
    public let lastAccessedAt: Date
    public let kind: FileEntryKind
    public init(path: String, lastAccessedAt: Date, kind: FileEntryKind = .directory) {
        self.path = path; self.lastAccessedAt = lastAccessedAt; self.kind = kind
    }
    private enum CodingKeys: String, CodingKey { case path, lastAccessedAt, kind }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(path: try container.decode(String.self, forKey: .path),
                  lastAccessedAt: try container.decode(Date.self, forKey: .lastAccessedAt),
                  kind: try container.decodeIfPresent(FileEntryKind.self, forKey: .kind) ?? .directory)
    }
}
/// Put Back uses only recorded origins, never guesses another app's trash origin (F-060).
public struct TrashedItem: Hashable, Sendable, Codable {
    public let trashedURL: URL
    public let originalURL: URL
    public init(trashedURL: URL, originalURL: URL) { self.trashedURL = trashedURL; self.originalURL = originalURL }
}
/// Supplies Recent without introducing a persistence/filesystem dependency cycle (F-030).
public protocol RecentRecordsProviding: Sendable { func recentRecords() async -> [RecentRecord] }
/// Persists known trash origins for Put Back across launches (F-060).
public protocol TrashOriginRecording: Sendable {
    func record(_ items: [TrashedItem]) async
    func originalURL(forTrashed url: URL) async -> URL?
}
