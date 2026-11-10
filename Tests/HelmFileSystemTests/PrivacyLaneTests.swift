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

    func testWithoutPrivacyLanesOneWaitingReadShutsTheWholeDisk() async throws {
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        let documents = temp.url.appendingPathComponent("Documents", isDirectory: true)
        let other = temp.url.appendingPathComponent("Other", isDirectory: true)
        for url in [documents, other] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false) }
        let gate = DispatchSemaphore(value: 0)
        let system = LiveFileSystem(executor: IOExecutor(timeout: 0.05), readMetadata: Self.blocking(inside: documents, on: gate))
        defer { for _ in 0..<4 { gate.signal() } }
        do { _ = try await system.entry(at: documents); XCTFail("The read is waiting on macOS") } catch {}
        do { _ = try await system.entry(at: other); XCTFail("The shared lane is shut") }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
    }

    private static func blocking(inside folder: URL, on gate: DispatchSemaphore) -> @Sendable (URL, Bool, String) throws -> FileEntry {
        let prefix = PathSpelling.standardPath(folder)
        return { url, resolve, volume in
            let path = PathSpelling.standardPath(url)
            if path == prefix || path.hasPrefix(prefix + "/") { gate.wait() }
            return try MetadataReader().read(url, resolveSymlinkTargets: resolve, volumeIdentifier: volume)
        }
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
