import Foundation
import HelmCore

/// One shared star store updates all windows; unavailable paths survive (F-029, B-027).
@MainActor public final class StarStore {
    private let file: JSONFileStore<[StarRecord]>
    public var records: [StarRecord] { file.items }
    public let changes: Broadcast<[StarRecord]>
    public var lastError: (any Error)? { file.lastError }
    public init(url: URL) async throws {
        file = JSONFileStore(url: url, empty: [])
        changes = file.changes
        try await file.load()
    }
    public func isStarred(_ url: URL) -> Bool {
        url.isFileURL && records.contains { $0.path == url.standardizedFileURL.path }
    }
    public func star(_ url: URL, at date: Date = Date()) {
        guard url.isFileURL, !isStarred(url) else { return }
        file.replace(with: (records + [StarRecord(path: url.standardizedFileURL.path, addedAt: date)]).sorted { $0.path < $1.path })
    }
    public func unstar(_ url: URL) {
        guard url.isFileURL else { return }
        file.replace(with: records.filter { $0.path != url.standardizedFileURL.path })
    }
    public func toggle(_ url: URL, at date: Date = Date()) {
        if isStarred(url) { unstar(url) } else { star(url, at: date) }
    }
    public func flush() async throws { try await file.flush() }
}
