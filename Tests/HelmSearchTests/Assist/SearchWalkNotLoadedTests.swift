import Foundation
import XCTest
import HelmCore
import HelmFileSystem
@testable import HelmSearch

/// The walk an AI search makes in a cloud folder: a folder whose names aren't on this Mac is never gone into, and one
/// that answers as not downloaded is counted rather than ending the walk. Nothing is fetched to search.
final class SearchWalkNotLoadedTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/search/Drive", isDirectory: true)
    private var notLoaded: URL { root.appendingPathComponent("Archive", isDirectory: true) }
    private var refusing: URL { root.appendingPathComponent("Shared", isDirectory: true) }

    private func context() -> SearchRankingContext {
        SearchRankingContext(query: SearchQuery(text: "", scope: .currentFolder(root), bookmarkPaths: [],
                                                homeDirectory: URL(fileURLWithPath: "/search"), lastDirectory: nil,
                                                showHidden: false, limit: 1000), preferredRoots: [])
    }

    private func fixture() async throws -> (SearchWalkCloudFixture, InMemoryFileSystem) {
        let base = InMemoryFileSystem()
        for folder in [URL(fileURLWithPath: "/search", isDirectory: true), root, notLoaded, refusing, root.appendingPathComponent("Loaded", isDirectory: true)] {
            try await base.createDirectory(at: folder)
        }
        for path in ["top.pdf", "Loaded/inside.pdf", "Archive/old.pdf", "Shared/team.pdf"] {
            try await base.createFileExclusively(at: root.appendingPathComponent(path), contents: Data([1]))
        }
        // macOS refuses to list this folder while downloads are off, as it does a folder that isn't loaded.
        await base.setFailure(.notDownloaded, at: refusing)
        return (SearchWalkCloudFixture(base: base, evicted: [notLoaded.path]), base)
    }

    private func walk(_ fs: SearchWalkCloudFixture, skipsNotLoaded: Bool,
                      diagnostics: SearchWalkDiagnostics) async throws -> [String] {
        let engine = SearchEngine(fileSystem: fs, resolver: SearchRootResolver(home: URL(fileURLWithPath: "/search"),
                                                                                computerRoots: [URL(fileURLWithPath: "/search")]))
        let request = SearchRequest(text: "", scope: .currentFolder(root))
        let batch = try await engine.collect(request, context: context(), options: SearchWalkOptions(skipsNotLoaded: skipsNotLoaded),
                                             diagnostic: { diagnostics.add($0) })
        return batch.results.map(\.entry.url.path).sorted()
    }

    func testAFolderThatIsntLoadedIsNeverEntered() async throws {
        let (fs, _) = try await fixture()
        let diagnostics = SearchWalkDiagnostics()
        let found = try await walk(fs, skipsNotLoaded: true, diagnostics: diagnostics)
        XCTAssertFalse(fs.touched.contains(notLoaded.path), "nothing asked of the folder that isn't loaded")
        XCTAssertFalse(found.contains(notLoaded.appendingPathComponent("old.pdf").path))
        XCTAssertTrue(found.contains(notLoaded.path), "the folder itself is still a result, found by its name")
        XCTAssertTrue(found.contains(root.appendingPathComponent("Loaded/inside.pdf").path), "loaded folders are walked")
        XCTAssertTrue(diagnostics.unreadable.contains(notLoaded.path), "the skipped folder is counted")
    }

    func testAFolderThatAnswersNotDownloadedIsCountedNotThrown() async throws {
        let (fs, _) = try await fixture()
        let diagnostics = SearchWalkDiagnostics()
        let found = try await walk(fs, skipsNotLoaded: true, diagnostics: diagnostics)
        XCTAssertTrue(diagnostics.unreadable.contains(refusing.path), "counted as unreadable")
        XCTAssertFalse(found.contains(refusing.appendingPathComponent("team.pdf").path))
        XCTAssertTrue(found.contains(root.appendingPathComponent("top.pdf").path), "the rest of the walk goes on")
    }

    func testWithoutTheOptionTheWalkIsAsBefore() async throws {
        let (fs, base) = try await fixture()
        await base.setFailure(nil, at: refusing)
        let found = try await walk(fs, skipsNotLoaded: false, diagnostics: SearchWalkDiagnostics())
        XCTAssertTrue(fs.touched.contains(notLoaded.path), "an ordinary walk goes into every folder")
        XCTAssertTrue(found.contains(notLoaded.appendingPathComponent("old.pdf").path))
        // And an ordinary walk still fails on an error it doesn't know, as it always has.
        await base.setFailure(.notDownloaded, at: refusing)
        do {
            _ = try await walk(fs, skipsNotLoaded: false, diagnostics: SearchWalkDiagnostics())
            XCTFail("not downloaded ends an ordinary walk")
        } catch {
            XCTAssertEqual(FileSystemError.mapping(error), .notDownloaded)
        }
    }

    func testTheRootItselfNotDownloadedEndsWithNothingAndNoThrow() async throws {
        let (fs, base) = try await fixture()
        await base.setFailure(.notDownloaded, at: root)
        let diagnostics = SearchWalkDiagnostics()
        let found = try await walk(fs, skipsNotLoaded: true, diagnostics: diagnostics)
        XCTAssertEqual(found, [])
        XCTAssertEqual(diagnostics.unreadable, [root.path])
    }
}

/// The diagnostics a walk reported, from any thread.
final class SearchWalkDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ diagnostic: SearchDiagnostic) {
        guard case .unreadable(let url) = diagnostic else { return }
        lock.lock(); paths.append(url.path); lock.unlock()
    }
    var unreadable: [String] { lock.lock(); defer { lock.unlock() }; return paths }
}

/// An in-memory tree where some folders are in a cloud and not loaded, and every path asked about is noted.
final class SearchWalkCloudFixture: FileSystem, @unchecked Sendable {
    let base: InMemoryFileSystem
    let evicted: Set<String>
    private let lock = NSLock()
    private var asked: Set<String> = []
    init(base: InMemoryFileSystem, evicted: Set<String>) { self.base = base; self.evicted = evicted }

    /// Every path whose details or listing were asked for.
    var touched: Set<String> { lock.lock(); defer { lock.unlock() }; return asked }
    private func note(_ url: URL) { lock.lock(); asked.insert(url.path); lock.unlock() }

    private func marked(_ entry: FileEntry) -> FileEntry {
        guard evicted.contains(entry.url.path) else { return entry }
        return FileEntry(url: entry.url, kind: entry.kind, isHidden: entry.isHidden, size: entry.size,
                         modificationDate: entry.modificationDate, cloudAvailability: .evicted)
    }
    func entry(at url: URL) async throws -> FileEntry {
        note(url)
        return marked(try await base.entry(at: url))
    }
    func enumerate(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<[FileEntry], Error> {
        note(directory)
        let base = self.base
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await batch in base.enumerate(directory, options: options) { continuation.yield(batch.map(self.marked)) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func exists(_ url: URL) async -> Bool { await base.exists(url) }
    func copyItem(at source: URL, to destination: URL) async throws { try await base.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) async throws { try await base.moveItem(at: source, to: destination) }
    func replaceItem(at destination: URL, with temporary: URL, backup: URL) async throws {
        try await base.replaceItem(at: destination, with: temporary, backup: backup)
    }
    func applyDirectoryMetadata(from source: URL, to destination: URL) async throws {
        try await base.applyDirectoryMetadata(from: source, to: destination)
    }
    func trashItem(at url: URL) async throws -> URL? { try await base.trashItem(at: url) }
    func removeItem(at url: URL) async throws { try await base.removeItem(at: url) }
    func createDirectory(at url: URL) async throws { try await base.createDirectory(at: url) }
    func createFileExclusively(at url: URL, contents: Data) async throws { try await base.createFileExclusively(at: url, contents: contents) }
    func createSymbolicLink(at url: URL, destination: URL) async throws { try await base.createSymbolicLink(at: url, destination: destination) }
    func createAlias(for url: URL, at destination: URL) async throws { try await base.createAlias(for: url, at: destination) }
    func volumeIdentifier(for url: URL) async throws -> String { try await base.volumeIdentifier(for: url) }
    func availableCapacity(of url: URL) async throws -> Int64 { try await base.availableCapacity(of: url) }
}
