import Foundation
import HelmCore

/// Recent uses the injected record boundary, prunes missing files and preserves access order (F-030).
public struct RecentSource: LocationSource {
    private let records: any RecentRecordsProviding
    private let fileSystem: any FileSystem
    public init(records: any RecentRecordsProviding, fileSystem: any FileSystem) {
        self.records = records; self.fileSystem = fileSystem
    }
    public func load(_ location: Location, options: LoadOptions = LoadOptions()) -> AsyncThrowingStream<LoadEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard location == .recent else { throw FileSystemError.unsupported }
                    let records = await records.recentRecords().sorted {
                        $0.lastAccessedAt == $1.lastAccessedAt ? $0.path < $1.path : $0.lastAccessedAt > $1.lastAccessedAt
                    }
                    var seen = Set<ItemID>()
                    var entries: [FileEntry] = []
                    for record in records {
                        try Task.checkCancellation()
                        let url = URL(fileURLWithPath: record.path)
                        guard let entry = try? await fileSystem.entry(at: url),
                              options.showHidden || !entry.isHidden,
                              seen.insert(entry.id).inserted else { continue }
                        entries.append(entry)
                        if entries.count == 180 { break }
                    }
                    continuation.yield(.batch(entries)); continuation.yield(.finished); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public func monitor(_ location: Location) -> (any DirectoryMonitor)? { nil }
}
