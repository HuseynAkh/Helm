import Foundation
import XCTest
import HelmCore
import HelmTestKit
@testable import HelmFileSystem

/// A read waiting on a macOS privacy question holds up only its own folder, never the whole disk.
final class PrivacyLaneTests: XCTestCase {
    func testFoldersMacOSAsksAboutGetLanesOfTheirOwn() {
        let system = LiveFileSystem(privacyRoots: [URL(fileURLWithPath: "/Users/me/Documents"), URL(fileURLWithPath: "/Users/me/Movies/TV")])
        XCTAssertEqual(system.queueKey(URL(fileURLWithPath: "/Users/me/Documents")), "/Users/me/Documents")
        XCTAssertEqual(system.queueKey(URL(fileURLWithPath: "/Users/me/Documents/Reports/2026")), "/Users/me/Documents")
        XCTAssertEqual(system.queueKey(URL(fileURLWithPath: "/Users/me/Movies/TV/Media")), "/Users/me/Movies/TV")
        // A name that only starts the same isn't inside; everything else is where it was.
        XCTAssertEqual(system.queueKey(URL(fileURLWithPath: "/Users/me/Documents2")), "/")
        XCTAssertEqual(system.queueKey(URL(fileURLWithPath: "/Users/me/Movies")), "/")
        XCTAssertEqual(system.queueKey(URL(fileURLWithPath: "/Users/me")), "/")
        XCTAssertEqual(system.queueKey(URL(fileURLWithPath: "/Volumes/USB/Documents")), "/Volumes/USB")
        XCTAssertEqual(LiveFileSystem().queueKey(URL(fileURLWithPath: "/Users/me/Documents")), "/")
        // The Mac's own disk ignores case, so every spelling of a folder shares its one lane.
        XCTAssertEqual(system.queueKey(URL(fileURLWithPath: "/users/me/documents/Notes")), "/Users/me/Documents")
        XCTAssertEqual(system.queueKey(URL(fileURLWithPath: "/Users/me/MOVIES/tv")), "/Users/me/Movies/TV")
    }

    func testAWaitingFolderLeavesTheRestOfTheDiskWorking() async throws {
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        let documents = temp.url.appendingPathComponent("Documents", isDirectory: true)
        let other = temp.url.appendingPathComponent("Other", isDirectory: true)
        for url in [documents, other] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        let gate = DispatchSemaphore(value: 0)
        let system = LiveFileSystem(executor: IOExecutor(timeout: 0.05), privacyRoots: [documents],
                                    readMetadata: Self.blocking(inside: documents, on: gate))
        defer { for _ in 0..<4 { gate.signal() } }
        do { _ = try await system.entry(at: documents); XCTFail("The read is waiting on macOS") }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
        // Before privacy lanes, this read failed too: every internal-disk path shared one quarantined lane.
        let entry = try await system.entry(at: other)
        XCTAssertEqual(entry.name, "Other")
        do { _ = try await system.entry(at: documents); XCTFail("Still waiting") }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
        // The question is answered: the stuck read returns and the folder opens.
        for _ in 0..<4 { gate.signal() }
        try await Task.sleep(nanoseconds: 100_000_000)
        let recovered = try await system.entry(at: documents)
        XCTAssertEqual(recovered.name, "Documents")
    }

    func testOutsideAPrivacyLaneAWaitingReadShutsOnlyItsFolder() async throws {
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        let documents = temp.url.appendingPathComponent("Documents", isDirectory: true)
        let notes = documents.appendingPathComponent("Notes", isDirectory: true)
        let other = temp.url.appendingPathComponent("Other", isDirectory: true)
        for url in [documents, notes, other] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        try Data("a".utf8).write(to: other.appendingPathComponent("a.txt"))
        let gate = DispatchSemaphore(value: 0), waits = Waits()
        let system = LiveFileSystem(executor: IOExecutor(timeout: 0.05), readMetadata: Self.blocking(inside: [documents], on: gate, counting: waits))
        defer { for _ in 0..<8 { gate.signal() } }
        XCTAssertEqual(system.queueKey(documents), system.queueKey(other), "one lane for both")
        do { _ = try await system.entry(at: documents); XCTFail("The read is waiting on macOS") }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
        XCTAssertEqual(waits.count, 1)

        // The read said which folder it read, so only that folder is shut and the rest of the lane carries on.
        let entry = try await system.entry(at: other)
        XCTAssertEqual(entry.name, "Other")
        let listed = try await Self.names(in: other, system)
        XCTAssertEqual(listed, ["a.txt"])
        // The folder and what is inside it, read or listed, however it is spelled, fail at once: none of them waits.
        let respelled = temp.url.appendingPathComponent("DOCUMENTS/notes", isDirectory: true)
        for url in [documents, notes, respelled] {
            do { _ = try await system.entry(at: url); XCTFail("\(url.path) is in the waiting folder") }
            catch { XCTAssertEqual(error as? FileSystemError, .timedOut, url.path) }
            do { _ = try await Self.names(in: url, system); XCTFail("\(url.path) is in the waiting folder") }
            catch { XCTAssertEqual(error as? FileSystemError, .timedOut, url.path) }
        }
        XCTAssertEqual(waits.count, 1, "nothing else waited on macOS")

        // The question is answered: the stuck read returns and the folder opens.
        for _ in 0..<8 { gate.signal() }
        let recovered = try await Self.until { (try? await system.entry(at: notes))?.name == "Notes" }
        XCTAssertTrue(recovered)
    }

    func testOutsideAPrivacyLaneReadsWaitingInTwoFoldersShutTheWholeDisk() async throws {
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        let documents = temp.url.appendingPathComponent("Documents", isDirectory: true)
        let pictures = temp.url.appendingPathComponent("Pictures", isDirectory: true)
        let other = temp.url.appendingPathComponent("Other", isDirectory: true)
        for url in [documents, pictures, other] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        let gate = DispatchSemaphore(value: 0)
        let system = LiveFileSystem(executor: IOExecutor(timeout: 0.05),
                                    readMetadata: Self.blocking(inside: [documents, pictures], on: gate, counting: Waits()))
        defer { for _ in 0..<8 { gate.signal() } }
        for url in [documents, pictures] {
            do { _ = try await system.entry(at: url); XCTFail("The read is waiting on macOS") }
            catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
        }
        // Two folders stuck at once looks like the disk itself, so the whole lane shuts.
        do { _ = try await system.entry(at: other); XCTFail("The shared lane is shut") }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
        for _ in 0..<8 { gate.signal() }
        let recovered = try await Self.until { (try? await system.entry(at: other))?.name == "Other" }
        XCTAssertTrue(recovered)
    }

    /// How many reads waited on the stand-in for macOS's question.
    private final class Waits: @unchecked Sendable {
        private let lock = NSLock()
        private var total = 0
        func add() { lock.lock(); total += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return total }
    }

    private static func blocking(inside folder: URL, on gate: DispatchSemaphore) -> @Sendable (URL, Bool, String) throws -> FileEntry {
        blocking(inside: [folder], on: gate, counting: Waits())
    }

    private static func blocking(inside folders: [URL], on gate: DispatchSemaphore,
                                 counting waits: Waits) -> @Sendable (URL, Bool, String) throws -> FileEntry {
        let prefixes = folders.map(PathSpelling.standardPath)
        return { url, resolve, volume in
            let path = PathSpelling.standardPath(url)
            if prefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { waits.add(); gate.wait() }
            return try MetadataReader().read(url, resolveSymlinkTargets: resolve, volumeIdentifier: volume)
        }
    }

    private static func names(in folder: URL, _ system: LiveFileSystem) async throws -> [String] {
        var names: [String] = []
        for try await batch in system.enumerate(folder) { names += batch.map(\.name) }
        return names.sorted()
    }

    /// Waits for `condition`, which other threads decide, without holding one of the test's own.
    private static func until(_ condition: @Sendable () async -> Bool) async throws -> Bool {
        for _ in 0..<1_000 {
            if await condition() { return true }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }
}

/// Why a read is refused is kept: macOS privacy (EPERM) apart from ordinary permissions (EACCES).
final class MetadataPrivacyTests: XCTestCase {
    func testOrdinaryPermissionsAreNeverTakenForPrivacy() throws {
        let temp = try TempDirectory()
        let open = temp.url.appendingPathComponent("Open", isDirectory: true)
        let dropBox = temp.url.appendingPathComponent("Drop Box", isDirectory: true)
        let locked = temp.url.appendingPathComponent("Locked", isDirectory: true)
        for url in [open, dropBox, locked] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        chmod(dropBox.path, 0o300); chmod(locked.path, 0o000)
        defer { chmod(dropBox.path, 0o755); chmod(locked.path, 0o755); try? temp.remove() }

        let readable = try MetadataReader().read(open)
        XCTAssertTrue(readable.isReadable); XCTAssertFalse(readable.isPrivacyProtected)
        for url in [dropBox, locked] {
            let entry = try MetadataReader().read(url)
            XCTAssertEqual(entry.kind, .directory)
            XCTAssertFalse(entry.isReadable, url.lastPathComponent)
            XCTAssertFalse(entry.isPrivacyProtected, url.lastPathComponent)
        }
        XCTAssertTrue(MetadataReader.readAccess(open.path) == (true, false))
        XCTAssertTrue(MetadataReader.readAccess(locked.path) == (false, false))
        XCTAssertTrue(MetadataReader.readAccess(temp.url.appendingPathComponent("missing").path) == (false, false))
    }

    /// A fixture can't make macOS refuse with EPERM, so the read check stands in for it: the whole read keeps
    /// the reason, which is what draws the plain folder icon and the privacy card.
    func testAMacOSRefusalIsRecordedAsPrivacy() throws {
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        let tv = temp.url.appendingPathComponent("TV", isDirectory: true)
        try FileManager.default.createDirectory(at: tv, withIntermediateDirectories: false)

        let refusedByMacOS = try MetadataReader(readCheck: { _ in EPERM }).read(tv)
        XCTAssertEqual(refusedByMacOS.kind, .directory)
        XCTAssertFalse(refusedByMacOS.isReadable)
        XCTAssertTrue(refusedByMacOS.isPrivacyProtected)

        let refusedByOwner = try MetadataReader(readCheck: { _ in EACCES }).read(tv)
        XCTAssertFalse(refusedByOwner.isReadable)
        XCTAssertFalse(refusedByOwner.isPrivacyProtected)

        let open = try MetadataReader(readCheck: { _ in 0 }).read(tv)
        XCTAssertTrue(open.isReadable)
        XCTAssertFalse(open.isPrivacyProtected)

        XCTAssertTrue(MetadataReader.readAccess(refusedWith: EPERM) == (false, true))
        XCTAssertTrue(MetadataReader.readAccess(refusedWith: EACCES) == (false, false))
        XCTAssertTrue(MetadataReader.readAccess(refusedWith: 0) == (true, false))
    }
}
