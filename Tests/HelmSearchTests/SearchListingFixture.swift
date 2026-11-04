// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import HelmCore
import HelmFileSystem

/// Test-only listing adapter varies delivery order and marks packages over an in-memory tree.
struct SearchListingFixture: FileSystem {
    let base: InMemoryFileSystem
    let reversed: Bool
    var onEnumerate: @Sendable (URL) -> Void = { _ in }
    func transform(_ entry: FileEntry) -> FileEntry {
        FileEntry(url: entry.url, kind: entry.url.pathExtension == "app" ? .package : entry.kind,
                  isHidden: entry.isHidden, size: entry.size, modificationDate: entry.modificationDate)
    }
    func entry(at url: URL) async throws -> FileEntry { transform(try await base.entry(at: url)) }
    func enumerate(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<[FileEntry], Error> {
        onEnumerate(directory)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var entries: [FileEntry] = []
                    for try await batch in base.enumerate(directory, options: options) { entries += batch.map(transform) }
                    if reversed { entries.reverse() }
                    for entry in entries {
                        try Task.checkCancellation()
                        continuation.yield([entry]); await Task.yield()
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func exists(_ url: URL) async -> Bool { await base.exists(url) }
    func copyItem(at source: URL, to destination: URL) async throws { try await base.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) async throws { try await base.moveItem(at: source, to: destination) }
    func replaceItem(at destination: URL, with temporary: URL, backup: URL) async throws { try await base.replaceItem(at: destination, with: temporary, backup: backup) }
    func applyDirectoryMetadata(from source: URL, to destination: URL) async throws { try await base.applyDirectoryMetadata(from: source, to: destination) }
    func trashItem(at url: URL) async throws -> URL? { try await base.trashItem(at: url) }
    func removeItem(at url: URL) async throws { try await base.removeItem(at: url) }
    func createDirectory(at url: URL) async throws { try await base.createDirectory(at: url) }
    func createFileExclusively(at url: URL, contents: Data) async throws { try await base.createFileExclusively(at: url, contents: contents) }
    func createSymbolicLink(at url: URL, destination: URL) async throws { try await base.createSymbolicLink(at: url, destination: destination) }
    func createAlias(for url: URL, at destination: URL) async throws { try await base.createAlias(for: url, at: destination) }
    func volumeIdentifier(for url: URL) async throws -> String { try await base.volumeIdentifier(for: url) }
    func availableCapacity(of url: URL) async throws -> Int64 { try await base.availableCapacity(of: url) }
}
