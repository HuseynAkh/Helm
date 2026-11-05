// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
import HelmFileSystem

struct K31RecoverableFileSystem: RecoverableDirectoryEnumerating {
    let base: InMemoryFileSystem
    let root: URL
    var fail: Bool = false
    func enumerateRecoverably(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<LoadEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.warning("Skipped unreadable child"))
            continuation.yield(.batch([FileEntry(url: root.appendingPathComponent("good"))]))
            if fail { continuation.finish(throwing: FileSystemError.timedOut) }
            else { continuation.yield(.finished); continuation.finish() }
        }
    }
    func enumerate(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<[FileEntry], Error> {
        base.enumerate(directory, options: options)
    }
    func entry(at url: URL) async throws -> FileEntry { try await base.entry(at: url) }
    func exists(_ url: URL) async -> Bool { await base.exists(url) }
    func copyItem(at source: URL, to destination: URL) async throws { throw FileSystemError.unsupported }
    func moveItem(at source: URL, to destination: URL) async throws { throw FileSystemError.unsupported }
    func replaceItem(at destination: URL, with temporary: URL, backup: URL) async throws { throw FileSystemError.unsupported }
    func applyDirectoryMetadata(from source: URL, to destination: URL) async throws { throw FileSystemError.unsupported }
    func trashItem(at url: URL) async throws -> URL? { throw FileSystemError.unsupported }
    func removeItem(at url: URL) async throws { throw FileSystemError.unsupported }
    func createDirectory(at url: URL) async throws { throw FileSystemError.unsupported }
    func createFileExclusively(at url: URL, contents: Data) async throws { throw FileSystemError.unsupported }
    func createSymbolicLink(at url: URL, destination: URL) async throws { throw FileSystemError.unsupported }
    func createAlias(for url: URL, at destination: URL) async throws { throw FileSystemError.unsupported }
    func volumeIdentifier(for url: URL) async throws -> String { "memory" }
    func availableCapacity(of url: URL) async throws -> Int64 { 0 }
}
