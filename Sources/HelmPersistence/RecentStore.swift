import Foundation
import HelmCore

/// Recent retains 300 records and displays 180 in recency order (F-030, B-030).
/// Missing metadata never permanently prunes transiently unavailable paths (B-029).
@MainActor public final class RecentStore: RecentRecordsProviding {
    public static let storedLimit: Int = 300
    public static let displayedLimit: Int = 180
    private let file: JSONFileStore<[RecentRecord]>
    public var records: [RecentRecord] { file.items }
    public let changes: Broadcast<[RecentRecord]>
    public var lastError: (any Error)? { file.lastError }
    public init(url: URL) async throws {
        file = JSONFileStore(url: url, empty: [])
        changes = file.changes
        try await file.load()
        let normalized = Self.merged(file.items)
        if normalized != file.items { file.replace(with: normalized) }
    }
    public func recordAccess(to url: URL, kind: FileEntryKind = .directory, at date: Date = Date()) {
        guard url.isFileURL else { return }
        file.replace(with: Self.merged(records + [RecentRecord(path: url.standardizedFileURL.path, lastAccessedAt: date, kind: kind)]))
    }
    public func recentRecords() async -> [RecentRecord] { Array(records.prefix(Self.displayedLimit)) }
    public func clear() { file.replace(with: []) }
    public func flush() async throws { try await file.flush() }
    static func merged(_ records: [RecentRecord]) -> [RecentRecord] {
        var byPath: [String: RecentRecord] = [:]
        for record in records {
            let path = URL(fileURLWithPath: record.path).standardizedFileURL.path
            if let old = byPath[path], old.lastAccessedAt >= record.lastAccessedAt { continue }
            byPath[path] = RecentRecord(path: path, lastAccessedAt: record.lastAccessedAt, kind: record.kind)
        }
        return Array(byPath.values.sorted {
            $0.lastAccessedAt == $1.lastAccessedAt ? $0.path < $1.path : $0.lastAccessedAt > $1.lastAccessedAt
        }.prefix(storedLimit))
    }
}
