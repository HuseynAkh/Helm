import Foundation
import HelmCore

/// One shared star store updates all windows; unavailable paths survive (F-029, B-027).
@MainActor public final class StarStore {
    private let file: JSONFileStore<[StarRecord]>
    private var starredPaths: Set<String> = []
    public var records: [StarRecord] { file.items }
    public let changes: Broadcast<[StarRecord]>
    public var lastError: (any Error)? { file.lastError }
    public init(url: URL) async throws {
        file = JSONFileStore(url: url, empty: [])
        changes = file.changes
        try await file.load()
        starredPaths = Set(file.items.map(\.path))
    }
    public func isStarred(_ url: URL) -> Bool {
        url.isFileURL && starredPaths.contains(url.standardizedFileURL.path)
    }
    public func star(_ url: URL, at date: Date = Date()) {
        guard url.isFileURL, !isStarred(url) else { return }
        starredPaths.insert(url.standardizedFileURL.path)
        file.replace(with: (records + [StarRecord(path: url.standardizedFileURL.path, addedAt: date)]).sorted { $0.path < $1.path })
    }
    public func unstar(_ url: URL) {
        guard url.isFileURL else { return }
        starredPaths.remove(url.standardizedFileURL.path)
        file.replace(with: records.filter { $0.path != url.standardizedFileURL.path })
    }
    /// A starred item that was renamed or moved stays starred, with the date it was starred.
    public func relocate(_ moves: PathMoves) {
        guard let next = moves.relocate(records, path: \.path, rebuild: { StarRecord(path: $1, addedAt: $0.addedAt) })
        else { return }
        starredPaths = Set(next.map(\.path))
        file.replace(with: next.sorted { $0.path < $1.path })
    }
    public func toggle(_ url: URL, at date: Date = Date()) {
        if isStarred(url) { unstar(url) } else { star(url, at: date) }
    }
    public func flush() async throws { try await file.flush() }
}
