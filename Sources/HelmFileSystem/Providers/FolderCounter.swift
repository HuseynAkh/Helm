import Foundation
import HelmCore

/// What's inside some items, counted as Nautilus's Properties counts it: every file and folder inside, hidden ones
/// too, and their size in bytes as each file says it is.
public struct FolderContentsCount: Sendable, Equatable {
    /// Files inside, a package such as an app counting as one. Links count as files and aren't followed.
    public var files: Int = 0
    /// Folders inside.
    public var folders: Int = 0
    /// The size of everything counted, a package's contents included.
    public var bytes: Int64 = 0
    /// Folders inside that couldn't be read, so what's in them isn't counted.
    public var unreadable: Int = 0
    /// Folders inside that are kept in a cloud and aren't on this Mac, so what's in them isn't counted. Counting never
    /// downloads them.
    public var notDownloaded: Int = 0
    /// The total passed what an Int64 holds and stopped there.
    public var overflowed: Bool = false
    public init() {}
    public var items: Int { files + folders }
    /// Whether some of what's inside wasn't counted.
    public var isPartial: Bool { unreadable > 0 || notDownloaded > 0 }

    mutating func add(bytes more: Int64) {
        guard more > 0, !overflowed else { return }
        let sum = bytes.addingReportingOverflow(more)
        if sum.overflow { bytes = .max; overflowed = true } else { bytes = sum.partialValue }
    }
}

/// Counts what's inside folders for Properties, folder by folder, with running totals while it goes.
public enum FolderCounter {
    /// One update: the totals so far, and whether the count is done.
    public struct Progress: Sendable, Equatable {
        public let count: FolderContentsCount
        public let finished: Bool
        public init(count: FolderContentsCount, finished: Bool) { self.count = count; self.finished = finished }
    }

    /// Counts everything inside `folders` and adds the size of `files`, the other items chosen, which count
    /// themselves. A folder that can't be read is noted and the count goes on; so is one kept in a cloud and not on
    /// this Mac, when downloads are off. Running totals come about ten times a second and the last update is the
    /// finished count. Stopping the stream's reader stops the count.
    ///
    /// Make the stream inside `DatalessGuard.off` to count without downloading anything, as Properties does.
    public static func count(folders: [URL], files: [FileEntry] = [], in fileSystem: any FileSystem,
                             every interval: Duration = .milliseconds(100)) -> AsyncStream<Progress> {
        AsyncStream { continuation in
            let task = Task {
                var count = FolderContentsCount()
                for file in files {
                    count.files += 1
                    count.add(bytes: file.size)
                }
                let clock = ContinuousClock()
                var lastSent = clock.now
                // Each entry: a folder to list, and whether it's inside a package, whose contents add bytes only.
                var pending: [(url: URL, inPackage: Bool)] = folders.map { ($0, false) }
                let options = EnumerationOptions(includeHidden: true, resolveSymlinkTargets: false)
                while let (folder, inPackage) = pending.popLast() {
                    if Task.isCancelled { break }
                    do {
                        for try await batch in fileSystem.enumerate(folder, options: options) {
                            for entry in batch {
                                switch entry.kind {
                                case .directory:
                                    if !inPackage { count.folders += 1 }
                                    pending.append((entry.url, inPackage))
                                case .package:
                                    if !inPackage { count.files += 1 }
                                    pending.append((entry.url, true))
                                default:
                                    if !inPackage { count.files += 1 }
                                    count.add(bytes: entry.size)
                                }
                            }
                            if Task.isCancelled { break }
                            if clock.now - lastSent >= interval {
                                lastSent = clock.now
                                continuation.yield(Progress(count: count, finished: false))
                            }
                        }
                    } catch {
                        if Task.isCancelled { break }
                        if FileSystemError.mapping(error) == .notDownloaded { count.notDownloaded += 1 } else { count.unreadable += 1 }
                    }
                }
                if !Task.isCancelled { continuation.yield(Progress(count: count, finished: true)) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
