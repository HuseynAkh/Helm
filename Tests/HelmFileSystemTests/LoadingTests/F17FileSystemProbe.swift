// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmFileSystem

actor F17ReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    let entered: XCTestExpectation
    init(entered: XCTestExpectation) { self.entered = entered }
    func wait() async {
        if released { return }
        entered.fulfill()
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

final class F17ReadCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var roots = 0
    private var probes = 0
    private var listings = 0
    func root() { lock.lock(); defer { lock.unlock() }; roots += 1 }
    func enumeration(batchSize: Int) {
        lock.lock(); defer { lock.unlock() }
        if batchSize == 1 { probes += 1 } else { listings += 1 }
    }
    func snapshot() -> [Int] { lock.lock(); defer { lock.unlock() }; return [roots, probes, listings] }
}

struct F17FileSystemProbe: FileSystem {
    let base: InMemoryFileSystem
    let counts: F17ReadCounts
    var gate: F17ReadGate? = nil
    func entry(at url: URL) async throws -> FileEntry {
        counts.root()
        if let gate { await gate.wait() }
        return try await base.entry(at: url)
    }
    func enumerate(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<[FileEntry], Error> {
        counts.enumeration(batchSize: options.batchSize)
        return base.enumerate(directory, options: options)
    }
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
