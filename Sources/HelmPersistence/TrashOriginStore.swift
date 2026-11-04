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
@MainActor public final class TrashOriginStore: TrashOriginRecording {
    private let file: JSONFileStore<[TrashOriginRecord]>
    public var records: [TrashOriginRecord] { file.items }
    public let changes: Broadcast<[TrashOriginRecord]>
    public var lastError: (any Error)? { file.lastError }
    public init(url: URL) async throws {
        file = JSONFileStore(url: url, empty: [])
        changes = file.changes
        try await file.load()
    }
    public func record(_ items: [TrashedItem]) async {
        record(items, at: Date())
    }
    public func record(_ items: [TrashedItem], at date: Date) {
        var result = records
        for item in items where item.trashedURL.isFileURL && item.originalURL.isFileURL {
            let path = item.trashedURL.standardizedFileURL.path
            result.removeAll { $0.trashedPath == path }
            result.append(TrashOriginRecord(trashedPath: path,
                originalPath: item.originalURL.standardizedFileURL.path, trashedAt: date))
        }
        file.replace(with: result.sorted { $0.trashedPath < $1.trashedPath })
    }
    public func originalURL(forTrashed url: URL) async -> URL? {
        guard url.isFileURL else { return nil }
        return records.first { $0.trashedPath == url.standardizedFileURL.path }.map { URL(fileURLWithPath: $0.originalPath) }
    }
    public func removeOrigins(for urls: [URL]) {
        let paths = Set(urls.filter(\.isFileURL).map { $0.standardizedFileURL.path })
        file.replace(with: records.filter { !paths.contains($0.trashedPath) })
    }
    public func flush() async throws { try await file.flush() }
}
