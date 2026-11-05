import Foundation
import HelmCore

/// Trash enumerates home and mounted-volume locations; denied access is visible, never an empty success (B-109).
public struct TrashSource: LocationSource {
    private let fileSystem: any FileSystem
    private let origins: any TrashOriginRecording
    public let directories: [URL]
    public init(fileSystem: any FileSystem, origins: any TrashOriginRecording, home: URL,
                volumeRoots: [URL] = [], userID: String) {
        self.fileSystem = fileSystem; self.origins = origins
        var paths = [home.appendingPathComponent(".Trash")]
        paths.append(contentsOf: volumeRoots.map { $0.appendingPathComponent(".Trashes").appendingPathComponent(userID) })
        var seen = Set<String>()
        directories = paths.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
    public func originalURL(forTrashed url: URL) async -> URL? { await origins.originalURL(forTrashed: url) }
    public func load(_ location: Location, options: LoadOptions = LoadOptions()) -> AsyncThrowingStream<LoadEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    guard location == .trash else { throw FileSystemError.unsupported }
                    for (index, directory) in directories.enumerated() {
                        do {
                            for try await batch in fileSystem.enumerate(directory, options: EnumerationOptions(
                                includeHidden: options.showHidden, batchSize: options.batchSize)) {
                                try Task.checkCancellation(); continuation.yield(.batch(batch))
                            }
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            let mapped = FileSystemError.mapping(error)
                            if mapped == .notFound { continue }
                            // Home Trash failing fails the load; a volume's Trash failing stays visible
                            // as a warning instead of hiding the user's own Trash (B-109).
                            if index == 0 { throw error }
                            continuation.yield(.warning("\(directory.path) unavailable: \(mapped)"))
                        }
                    }
                    continuation.yield(.finished); continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    public func monitor(_ location: Location) -> (any DirectoryMonitor)? { nil }
}
