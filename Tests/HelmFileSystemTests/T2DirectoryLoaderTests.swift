// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmFileSystem

// F-035/F-042/B-073: cache and targeted refresh must agree with fresh enumeration.
final class T2DirectoryLoaderTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/t2")
    private func fixture() async throws -> (InMemoryFileSystem, DirectoryLoader) {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        for name in ["file10", "file2", ".hidden"] {
            try await fs.createFileExclusively(at: root.appendingPathComponent(name), contents: Data([1]))
        }
        return (fs, DirectoryLoader(fileSystem: fs))
    }
    func testCacheHitValidatesAccessWithoutFullEnumerationAndPartitionsVisibility() async throws {
        let probe = F18ListingProbe()
        let loader = DirectoryLoader(fileSystem: F18CountingFS(probe: probe))
        let location = Location.directory(root)
        let first = try await loader.snapshot(location)
        XCTAssertEqual(probe.fullReads, 1)
        let cached = try await loader.snapshot(location)
        XCTAssertEqual(cached, first)
        XCTAssertEqual(probe.fullReads, 1)
        XCTAssertEqual(probe.validationReads, 1)
        let descending = try await loader.snapshot(location, options: LoadOptions(sort: ItemSort(ascending: false)))
        XCTAssertEqual(descending.map(\.name), ["file10", "file2"])
        XCTAssertEqual(probe.fullReads, 1) // Cache holds entries, sorting is a projection.
        XCTAssertEqual(probe.validationReads, 2)
        let shown = try await loader.snapshot(location, options: LoadOptions(showHidden: true))
        XCTAssertEqual(shown.count, 3); XCTAssertEqual(probe.fullReads, 2)
        _ = try await loader.snapshot(location, options: LoadOptions(showHidden: true))
        XCTAssertEqual(probe.fullReads, 2); XCTAssertEqual(probe.validationReads, 3)
        _ = try await loader.snapshot(location, options: LoadOptions(useCache: false))
        XCTAssertEqual(probe.fullReads, 3)
        _ = try await loader.refresh(location: location, changed: [root.path], current: first)
        XCTAssertEqual(probe.fullReads, 4)
        XCTAssertEqual(probe.rootReads, 10)
    }
    func testCachedAndFreshOrderingAgree() async throws {
        let (_, loader) = try await fixture()
        let first = try await loader.snapshot(.directory(root))
        let cached = try await loader.snapshot(.directory(root))
        let fresh = try await loader.snapshot(.directory(root), options: LoadOptions(useCache: false))
        XCTAssertEqual(first.map(\.name), ["file2", "file10"])
        XCTAssertEqual(cached, first)
        XCTAssertEqual(fresh, first)
    }
    func testHiddenCachePartition() async throws {
        let (_, loader) = try await fixture()
        let shown = try await loader.snapshot(.directory(root), options: LoadOptions(showHidden: true))
        let hidden = try await loader.snapshot(.directory(root))
        XCTAssertEqual(shown.count, 3)
        XCTAssertEqual(hidden.count, 2)
    }
    func testCacheDoesNotBypassPermissionFailure() async throws {
        let (fs, loader) = try await fixture()
        _ = try await loader.snapshot(.directory(root))
        await fs.setFailure(.permissionDenied, at: root)
        do { _ = try await loader.snapshot(.directory(root)); XCTFail("Cache bypassed access check") }
        catch { XCTAssertEqual(error as? FileSystemError, .permissionDenied) }
    }
    func testRefreshAddsDirectChild() async throws {
        let (fs, loader) = try await fixture()
        let before = try await loader.snapshot(.directory(root))
        let added = root.appendingPathComponent("file1")
        try await fs.createFileExclusively(at: added, contents: Data())
        let after = try await loader.refresh(location: .directory(root), changed: [added.path], current: before)
        XCTAssertEqual(after.map(\.name), ["file1", "file2", "file10"])
    }
    func testRefreshRemovesMissingDirectChild() async throws {
        let (fs, loader) = try await fixture()
        let before = try await loader.snapshot(.directory(root))
        let removed = root.appendingPathComponent("file2")
        try await fs.removeItem(at: removed)
        let after = try await loader.refresh(location: .directory(root), changed: [removed.path], current: before)
        XCTAssertEqual(after.map(\.name), ["file10"])
    }
    func testRefreshIgnoresGrandchildrenAndOtherRoots() async throws {
        let (_, loader) = try await fixture()
        let before = try await loader.snapshot(.directory(root))
        let after = try await loader.refresh(location: .directory(root), changed: ["/elsewhere/x", "/t2/sub/file"], current: before)
        XCTAssertEqual(after, before)
    }
    func testRootChangeReconcilesEntireListing() async throws {
        let (fs, loader) = try await fixture()
        let before = try await loader.snapshot(.directory(root))
        try await fs.removeItem(at: root.appendingPathComponent("file2"))
        try await fs.createFileExclusively(at: root.appendingPathComponent("file3"), contents: Data())
        let after = try await loader.refresh(location: .directory(root), changed: [root.path], current: before)
        XCTAssertEqual(after.map(\.name), ["file3", "file10"])
    }
    func testRefreshPermissionErrorIsNotDeletion() async throws {
        let (fs, loader) = try await fixture()
        let before = try await loader.snapshot(.directory(root))
        let path = root.appendingPathComponent("file2")
        await fs.setFailure(.permissionDenied, at: path)
        do { _ = try await loader.refresh(location: .directory(root), changed: [path.path], current: before); XCTFail("Access failure treated as deletion") }
        catch { XCTAssertEqual(error as? FileSystemError, .permissionDenied) }
    }
    func testPrecancelledSnapshotRefusesWork() async throws {
        let (_, loader) = try await fixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await loader.snapshot(.directory(root)); XCTFail("Cancellation ignored") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
    }
    func testVirtualSnapshotRefused() async throws {
        let (_, loader) = try await fixture()
        do { _ = try await loader.snapshot(.recent); XCTFail("Virtual location enumerated as directory") }
        catch { XCTAssertEqual(error as? FileSystemError, .unsupported) }
    }
}

extension T2DirectoryLoaderTests {
    func testCacheHitValidatesAccessWithoutFullEnumeration() async throws {
        let (base, _) = try await fixture()
        let counts = F17ReadCounts()
        let loader = DirectoryLoader(fileSystem: F17FileSystemProbe(base: base, counts: counts))
        let first = try await loader.snapshot(.directory(root))
        XCTAssertEqual(counts.snapshot(), [2, 0, 1])
        XCTAssertEqual(first.map(\.name), ["file2", "file10"])
        let cached = try await loader.snapshot(.directory(root))
        XCTAssertEqual(cached, first)
        XCTAssertEqual(counts.snapshot(), [3, 1, 1])
        let reversed = try await loader.snapshot(.directory(root), options: LoadOptions(sort: ItemSort(ascending: false)))
        XCTAssertEqual(reversed.map(\.name), ["file10", "file2"])
        XCTAssertEqual(counts.snapshot(), [4, 2, 1])
        let shown = try await loader.snapshot(.directory(root), options: LoadOptions(showHidden: true))
        XCTAssertEqual(shown.count, 3)
        XCTAssertEqual(counts.snapshot(), [6, 2, 2])
        _ = try await loader.snapshot(.directory(root), options: LoadOptions(showHidden: true))
        XCTAssertEqual(counts.snapshot(), [7, 3, 2])
        _ = try await loader.snapshot(.directory(root), options: LoadOptions(useCache: false))
        XCTAssertEqual(counts.snapshot(), [8, 3, 3])
        _ = try await loader.refresh(location: .directory(root), changed: [root.path], current: first)
        XCTAssertEqual(counts.snapshot(), [10, 3, 4])
    }
}

// Independent counters distinguish required open-access validation from a full read.
private final class F18ListingProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var full = 0
    private var validation = 0
    private var roots = 0
    var fullReads: Int { lock.lock(); defer { lock.unlock() }; return full }
    var validationReads: Int { lock.lock(); defer { lock.unlock() }; return validation }
    var rootReads: Int { lock.lock(); defer { lock.unlock() }; return roots }
    func rootRead() { lock.lock(); roots += 1; lock.unlock() }
    func enumeration(batchSize: Int) {
        lock.lock(); defer { lock.unlock() }
        if batchSize == 1 { validation += 1 } else { full += 1 }
    }
}
private struct F18CountingFS: FileSystem {
    let probe: F18ListingProbe
    func entry(at url: URL) async throws -> FileEntry {
        probe.rootRead()
        return FileEntry(url: url, kind: .directory)
    }
    func enumerate(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<[FileEntry], Error> {
        probe.enumeration(batchSize: options.batchSize)
        return AsyncThrowingStream { continuation in
            let names = options.includeHidden ? ["file10", "file2", ".hidden"] : ["file10", "file2"]
            continuation.yield(names.map { FileEntry(url: directory.appendingPathComponent($0)) })
            continuation.finish()
        }
    }
    func exists(_ url: URL) async -> Bool { true }
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
