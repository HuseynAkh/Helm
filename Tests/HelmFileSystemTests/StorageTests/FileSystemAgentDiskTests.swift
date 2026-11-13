import Foundation
import XCTest
import HelmCore
import HelmTestKit
@testable import HelmFileSystem

/// AI mode's read-only disk over a real file system: over the in-memory disk, which can stand in for a cloud, and
/// over a temporary folder on this Mac.
final class FileSystemAgentDiskTests: XCTestCase {
    private let home = "/home/helm"

    /// Home holds Documents, Downloads, a mirror target, a link to Downloads, a hidden file and a few files.
    private func memoryHome() async throws -> InMemoryFileSystem {
        let disk = InMemoryFileSystem()
        for folder in ["/home", home, home + "/Documents", home + "/Downloads", home + "/Mirror", home + "/Documents/Reports"] {
            try await disk.createDirectory(at: URL(fileURLWithPath: folder))
        }
        for file in ["a 10.txt", "a 9.txt", "B.txt", ".hidden", "Documents/Plan.pdf"] {
            try await disk.createFileExclusively(at: URL(fileURLWithPath: home + "/" + file), contents: Data("x".utf8))
        }
        try await disk.createSymbolicLink(at: URL(fileURLWithPath: home + "/Linked"), destination: URL(fileURLWithPath: home + "/Downloads"))
        return disk
    }

    private func agentDisk(_ fileSystem: any FileSystem, _ storage: (any StorageFactsReading)? = nil) -> FileSystemAgentDisk {
        FileSystemAgentDisk(fileSystem: fileSystem, storage: storage ?? MemoryStorageFactsReader(home: URL(fileURLWithPath: home)),
                            home: home, canonical: { $0 })
    }

    // MARK: Listing

    func testAListingIsSortedFilteredAndLimited() async throws {
        let disk = agentDisk(try await memoryHome())
        let all = await disk.list(home, limit: 100, idleSeconds: 2)
        XCTAssertEqual(all.state, .ok)
        XCTAssertEqual(all.items.map(\.name), ["a 9.txt", "a 10.txt", "B.txt", "Documents", "Downloads", "Linked", "Mirror"],
                       "by name without case, numbers by value, and no hidden names")
        XCTAssertEqual(all.more, 0)
        XCTAssertEqual(all.unreadable, 0)
        XCTAssertEqual(all.items.first { $0.name == "Documents" }?.path, home + "/Documents")
        let some = await disk.list(home, limit: 2, idleSeconds: 2)
        XCTAssertEqual(some.items.map(\.name), ["a 9.txt", "a 10.txt"])
        XCTAssertEqual(some.more, 5)
        let missing = await disk.list(home + "/Gone", limit: 10, idleSeconds: 2)
        XCTAssertEqual(missing.state, .gone)
        let file = await disk.list(home + "/B.txt", limit: 10, idleSeconds: 2)
        XCTAssertEqual(file.state, .gone, "a file isn't a folder to list")
    }

    func testLinksAreNotFollowedInMemory() async throws {
        let fileSystem = try await memoryHome()
        let disk = agentDisk(fileSystem)
        let link = await disk.item(at: home + "/Linked")
        let target = await disk.item(at: home + "/Downloads")
        XCTAssertEqual(link?.path, home + "/Linked")
        XCTAssertEqual(link?.kind, .symlinkToDirectory)
        XCTAssertNotNil(link?.identity)
        XCTAssertNotEqual(link?.identity, target?.identity, "the link itself, not what it points at")
        let throughLink = await disk.list(home + "/Linked", limit: 10, idleSeconds: 2)
        XCTAssertEqual(throughLink.state, .gone)
        XCTAssertEqual(throughLink.items, [])
        let reads = await fileSystem.reads
        XCTAssertFalse(reads.contains(home + "/Linked") || reads.contains(home + "/Downloads"), "\(reads)")
        let listed = await disk.list(home, limit: 10, idleSeconds: 2)
        let child = listed.items.first { $0.name == "Linked" }
        XCTAssertEqual(child?.kind, .danglingSymlink, "a listing doesn't look at where a link points")
    }

    func testLinksAreNotFollowedOnThisMac() async throws {
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        let folder = temp.url.appendingPathComponent("Target"), link = temp.url.appendingPathComponent("Linked")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: folder.appendingPathComponent("inside.txt"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        let disk = FileSystemAgentDisk(fileSystem: LiveFileSystem(), storage: MemoryStorageFactsReader(home: temp.url), home: temp.url.path)
        let item = await disk.item(at: link.path)
        XCTAssertEqual(item?.kind, .symlinkToDirectory)
        XCTAssertEqual(item?.path, link.path)
        let targetItem = await disk.item(at: folder.path)
        XCTAssertNotEqual(item?.identity, targetItem?.identity)
        let throughLink = await disk.list(link.path, limit: 10, idleSeconds: 2)
        XCTAssertEqual(throughLink.state, .gone, "a link is never listed through")
        XCTAssertEqual(throughLink.items, [])
        let listed = await disk.list(temp.url.path, limit: 10, idleSeconds: 2)
        XCTAssertEqual(listed.items.map(\.name), ["Linked", "Target"])
        XCTAssertEqual(listed.items.first?.kind, .danglingSymlink)
        XCTAssertEqual(listed.items.last?.kind, .directory)
    }

    func testANotLoadedFolderAnswersNotLoadedAndIsNeverListed() async throws {
        let fileSystem = try await memoryHome()
        await fileSystem.setCloudAvailability(.evicted, at: URL(fileURLWithPath: home + "/Documents"))
        await fileSystem.setCloudAvailability(.evicted, at: URL(fileURLWithPath: home + "/B.txt"))
        let disk = agentDisk(fileSystem)
        let listing = await disk.list(home + "/Documents", limit: 10, idleSeconds: 2)
        XCTAssertEqual(listing.state, .notLoaded)
        XCTAssertEqual(listing.items, [])
        let reads = await fileSystem.reads
        XCTAssertEqual(reads, [], "its names were never asked for")
        // In its parent's listing it is there, marked; so is a file that isn't downloaded.
        let parent = await disk.list(home, limit: 10, idleSeconds: 2)
        XCTAssertEqual(parent.items.filter(\.isDataless).map(\.name), ["B.txt", "Documents"])
        let file = await disk.item(at: home + "/B.txt")
        XCTAssertEqual(file?.isDataless, true)
        XCTAssertEqual(file?.size, 1, "a file that isn't downloaded still has its details")
        // A folder whose listing macOS refuses with downloads off is not loaded either.
        let refusing = StorageRecordingFileSystem(inner: try await memoryHome(), home: home)
        refusing.refuseListing(home + "/Downloads")
        let refused = await agentDisk(refusing).list(home + "/Downloads", limit: 10, idleSeconds: 2)
        XCTAssertEqual(refused.state, .notLoaded)
    }

    func testADelayedFolderAnswersSlowAfterTheIdleLimit() async throws {
        let fileSystem = try await memoryHome()
        await fileSystem.setDelay(6, under: URL(fileURLWithPath: home + "/Documents"))
        let disk = agentDisk(fileSystem)
        let start = Date()
        let listing = await disk.list(home + "/Documents", limit: 10, idleSeconds: 0.4)
        let waited = Date().timeIntervalSince(start)
        XCTAssertEqual(listing.state, .slow)
        XCTAssertEqual(listing.items, [])
        XCTAssertGreaterThanOrEqual(waited, 0.39)
        XCTAssertLessThan(waited, 4, "it gave up on the place rather than waiting it out")
        // The rest of the disk still answers.
        let quick = await disk.list(home, limit: 10, idleSeconds: 0.4)
        XCTAssertEqual(quick.state, .ok)
        // The other questions have their own limit and answer nothing from a place that stopped answering.
        let item = await disk.item(at: home + "/Documents/Plan.pdf")
        XCTAssertNil(item)
    }

    func testAListingThatKeepsMovingIsNotCutOff() async throws {
        let slow = StorageRecordingFileSystem(inner: try await memoryHome(), home: home)
        slow.batchPause = 0.3
        // Eight names, one every 0.3 seconds: longer in all than the limit, never that long without one.
        let start = Date()
        let listing = await agentDisk(slow).list(home, limit: 100, idleSeconds: 1.5)
        XCTAssertGreaterThan(Date().timeIntervalSince(start), 1.5)
        XCTAssertEqual(listing.state, .ok, "seconds without progress count, not seconds in all")
        XCTAssertEqual(listing.items.count, 7)
    }

    func testCanonicalPathIsNilForAMissingPart() async throws {
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        let folder = temp.url.appendingPathComponent("Real")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("Link"), withDestinationURL: folder)
        let disk = FileSystemAgentDisk(fileSystem: LiveFileSystem(), storage: MemoryStorageFactsReader(home: temp.url), home: temp.url.path)
        let real = CanonicalPath.realPath(folder.path)
        let viaLink = await disk.canonicalPath(temp.url.appendingPathComponent("Link").path)
        XCTAssertEqual(viaLink, real)
        let missingPart = await disk.canonicalPath(temp.url.appendingPathComponent("Gone/Real").path)
        XCTAssertNil(missingPart)
        let missingEnd = await disk.canonicalPath(folder.appendingPathComponent("Gone").path)
        XCTAssertNil(missingEnd)

        let memory = agentDisk(try await memoryHome())
        let found = await memory.canonicalPath(home + "/Documents/Reports")
        XCTAssertEqual(found, home + "/Documents/Reports")
        let gone = await memory.canonicalPath(home + "/Gone/Reports")
        XCTAssertNil(gone, "the file system can't see it")
    }

    func testAChildFolderWithOtherFactsCarriesItsPlace() async throws {
        let facts = MemoryStorageFactsReader(home: URL(fileURLWithPath: home))
        facts.set(StorageProbe(isUbiquitous: true), under: home + "/Documents")
        facts.setMirror(target: home + "/Mirror", cloudFolder: "GoogleDrive-me@example.com")
        let disk = agentDisk(try await memoryHome(), facts)
        let listing = await disk.list(home, limit: 10, idleSeconds: 2)
        let places = Dictionary(uniqueKeysWithValues: listing.items.map { ($0.name, $0.place) })
        XCTAssertEqual(places["Documents"]??.kind, .iCloud)
        XCTAssertEqual(places["Mirror"]??.name, "Google Drive")
        XCTAssertEqual(places["Downloads"], .some(nil), "an ordinary child is where its folder is")
        XCTAssertEqual(places["B.txt"], .some(nil))
        // Only the children that can be somewhere else were asked about, beside the folder listed.
        XCTAssertEqual(Set(facts.asked), [home, home + "/Documents", home + "/Mirror"])
        // Inside Documents, every folder is where Documents is.
        let inside = await disk.list(home + "/Documents", limit: 10, idleSeconds: 2)
        XCTAssertEqual(inside.items.map(\.name), ["Plan.pdf", "Reports"])
        XCTAssertTrue(inside.items.allSatisfy { $0.place == nil })
        // The folder's own facts come from the reader.
        let documents = await disk.storage(of: home + "/Documents")
        XCTAssertEqual(documents.kind, .iCloud)
    }

    func testAnUnreadableChildIsSkippedAndCounted() async throws {
        let fileSystem = try await memoryHome()
        await fileSystem.setFailure(.permissionDenied, at: URL(fileURLWithPath: home + "/B.txt"))
        let listing = await agentDisk(fileSystem).list(home, limit: 10, idleSeconds: 2)
        XCTAssertEqual(listing.state, .ok)
        XCTAssertEqual(listing.unreadable, 1)
        XCTAssertFalse(listing.items.contains { $0.name == "B.txt" })
        XCTAssertEqual(listing.items.count, 6)

        // On this Mac, a child macOS won't describe with downloads off.
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        for name in ["a.txt", "cloud.txt", "c.txt"] { try Data("x".utf8).write(to: temp.url.appendingPathComponent(name)) }
        let live = LiveFileSystem(readMetadata: { url, resolve, volume in
            if url.lastPathComponent == "cloud.txt" { throw FileSystemError.notDownloaded }
            return try MetadataReader().read(url, resolveSymlinkTargets: resolve, volumeIdentifier: volume)
        })
        let disk = FileSystemAgentDisk(fileSystem: live, storage: MemoryStorageFactsReader(home: temp.url), home: temp.url.path)
        let onThisMac = await disk.list(temp.url.path, limit: 10, idleSeconds: 2)
        XCTAssertEqual(onThisMac.state, .ok)
        XCTAssertEqual(onThisMac.items.map(\.name), ["a.txt", "c.txt"])
        XCTAssertEqual(onThisMac.unreadable, 1)
        // The same listing made without downloads off fails as it always has.
        do { for try await _ in live.enumerate(temp.url) {}; XCTFail("listed") }
        catch { XCTAssertEqual(error as? FileSystemError, .notDownloaded) }
    }

    func testEveryMethodRunsWithDownloadsOff() async throws {
        let recording = StorageRecordingFileSystem(inner: try await memoryHome(), home: home)
        let threads = StorageThreadPolicies()
        let disk = FileSystemAgentDisk(fileSystem: recording, storage: recording, home: home,
                                       canonical: { threads.add(DatalessGuard.threadPolicyIsOffForTesting); return $0 })
        _ = await recording.entry(home)
        XCTAssertEqual(recording.take().map(\.isOff), [false], "the recording sees an ordinary call as one")

        _ = await disk.canonicalPath(home + "/Documents")
        XCTAssertEqual(threads.take(), [true], "realpath ran on a thread with downloads off")
        assertAllOff(recording.take(), "canonicalPath")
        _ = await disk.item(at: home + "/B.txt")
        assertAllOff(recording.take(), "item")
        _ = await disk.list(home, limit: 10, idleSeconds: 2)
        let listed = recording.take()
        assertAllOff(listed, "list")
        XCTAssertTrue(listed.contains { $0.call == "enumerate" })
        _ = await disk.storage(of: home + "/Documents")
        let stored = recording.take()
        assertAllOff(stored, "storage")
        XCTAssertTrue(stored.contains { $0.call == "facts" })
    }

    private func assertAllOff(_ calls: [StorageRecordingFileSystem.Call], _ method: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(calls.isEmpty, "\(method) asked nothing", file: file, line: line)
        XCTAssertTrue(calls.allSatisfy(\.isOff), "\(method): \(calls)", file: file, line: line)
    }
}

/// What threads saw, gathered from wherever they ran.
private final class StorageThreadPolicies: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [Bool] = []
    func add(_ value: Bool) { lock.lock(); seen.append(value); lock.unlock() }
    func take() -> [Bool] { lock.lock(); defer { seen.removeAll(); lock.unlock() }; return seen }
}

/// A file system and a place-facts reader in one, over the in-memory disk, that notes each call and whether the
/// task making it had downloads off. It can refuse a listing as macOS refuses a folder that isn't loaded, and can
/// pause between the batches of a listing.
private final class StorageRecordingFileSystem: FileSystem, StorageFactsReading, @unchecked Sendable {
    struct Call: Sendable { let call: String, isOff: Bool }
    private let inner: InMemoryFileSystem
    private let facts: MemoryStorageFactsReader
    private let lock = NSLock()
    private var calls: [Call] = []
    private var refused: Set<String> = []
    var batchPause: Double {
        get { lock.lock(); defer { lock.unlock() }; return pause }
        set { lock.lock(); pause = newValue; lock.unlock() }
    }
    private var pause: Double = 0

    init(inner: InMemoryFileSystem, home: String) {
        self.inner = inner
        facts = MemoryStorageFactsReader(home: URL(fileURLWithPath: home))
    }
    func refuseListing(_ path: String) { lock.lock(); refused.insert(path); lock.unlock() }
    func take() -> [Call] { lock.lock(); defer { calls.removeAll(); lock.unlock() }; return calls }
    private func note(_ call: String) { lock.lock(); calls.append(Call(call: call, isOff: DatalessGuard.isOff)); lock.unlock() }
    func entry(_ path: String) async -> FileEntry? { try? await entry(at: URL(fileURLWithPath: path)) }

    func enumerate(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<[FileEntry], Error> {
        note("enumerate")
        lock.lock(); let refuse = refused.contains(directory.path), pause = self.pause; lock.unlock()
        if refuse { return AsyncThrowingStream { $0.finish(throwing: FileSystemError.notDownloaded) } }
        let inner = self.inner
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await batch in inner.enumerate(directory, options: options) {
                        for entry in batch {
                            if pause > 0 { try await Task.sleep(nanoseconds: UInt64(pause * 1_000_000_000)) }
                            continuation.yield([entry])
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
    func entry(at url: URL) async throws -> FileEntry { note("entry"); return try await inner.entry(at: url) }
    func exists(_ url: URL) async -> Bool { note("exists"); return await inner.exists(url) }
    func copyItem(at source: URL, to destination: URL) async throws { note("copy"); try await inner.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) async throws { note("move"); try await inner.moveItem(at: source, to: destination) }
    func replaceItem(at destination: URL, with temporary: URL, backup: URL) async throws {
        note("replace"); try await inner.replaceItem(at: destination, with: temporary, backup: backup)
    }
    func applyDirectoryMetadata(from source: URL, to destination: URL) async throws {
        note("metadata"); try await inner.applyDirectoryMetadata(from: source, to: destination)
    }
    func trashItem(at url: URL) async throws -> URL? { note("trash"); return try await inner.trashItem(at: url) }
    func removeItem(at url: URL) async throws { note("remove"); try await inner.removeItem(at: url) }
    func createDirectory(at url: URL) async throws { note("mkdir"); try await inner.createDirectory(at: url) }
    func createFileExclusively(at url: URL, contents: Data) async throws {
        note("create"); try await inner.createFileExclusively(at: url, contents: contents)
    }
    func createSymbolicLink(at url: URL, destination: URL) async throws {
        note("symlink"); try await inner.createSymbolicLink(at: url, destination: destination)
    }
    func createAlias(for url: URL, at destination: URL) async throws { note("alias"); try await inner.createAlias(for: url, at: destination) }
    func volumeIdentifier(for url: URL) async throws -> String { note("volume"); return try await inner.volumeIdentifier(for: url) }
    func availableCapacity(of url: URL) async throws -> Int64 { note("capacity"); return try await inner.availableCapacity(of: url) }

    func facts(for folder: URL) async -> StorageFacts { note("facts"); return await facts.facts(for: folder) }
    func mirrors() async -> [String: String] { note("mirrors"); return await facts.mirrors() }
}
