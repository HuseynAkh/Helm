import Foundation
import XCTest
import HelmCore
@testable import HelmFileSystem

/// The fixture runs' disk: the real answers, plus marks for what a fixture folder can't be. A mark outside the
/// fixture's own folder is ignored, so a run can't change how any other folder looks.
final class InjectedAgentDiskTests: XCTestCase {
    /// Spelled as /tmp is on a Mac, under a name no real folder has.
    private let home = "/private/tmp/helm-injected-" + UUID().uuidString + "/home"

    private func makeDisks() async throws -> (InjectedAgentDisk, InMemoryFileSystem) {
        let fileSystem = InMemoryFileSystem()
        var folder = ""
        for part in home.split(separator: "/") {
            folder += "/" + part
            try await fileSystem.createDirectory(at: URL(fileURLWithPath: folder))
        }
        for name in ["Cloud", "Cloud/Album", "Elsewhere", "Cloud2"] { try await fileSystem.createDirectory(at: URL(fileURLWithPath: home + "/" + name)) }
        for name in ["Cloud/a.pdf", "Cloud/b.pdf", "Elsewhere/c.pdf", "Cloud2/d.pdf"] {
            try await fileSystem.createFileExclusively(at: URL(fileURLWithPath: home + "/" + name), contents: Data("x".utf8))
        }
        let base = FileSystemAgentDisk(fileSystem: fileSystem, storage: MemoryStorageFactsReader(home: URL(fileURLWithPath: home)),
                                       home: home, canonical: { $0 })
        // Allowed as the fixture names it, without /private: the marks below use the disk's own spelling.
        let allowed = String(home.dropFirst("/private".count)) + "/Cloud"
        return (InjectedAgentDisk(base: base, allowedPrefix: allowed), fileSystem)
    }

    func testCloudOnlyAndNotLoadedMarks() async throws {
        let (disk, fileSystem) = try await makeDisks()
        disk.markCloudOnly(home + "/Cloud/a.pdf")
        disk.markNotLoaded(home + "/Cloud/Album")
        let file = await disk.item(at: home + "/Cloud/a.pdf")
        XCTAssertEqual(file?.isDataless, true)
        XCTAssertEqual(file?.size, 1, "everything else is the real answer")
        let other = await disk.item(at: home + "/Cloud/b.pdf")
        XCTAssertEqual(other?.isDataless, false)
        let listing = await disk.list(home + "/Cloud", limit: 10, idleSeconds: 2)
        XCTAssertEqual(listing.items.filter(\.isDataless).map(\.name), ["a.pdf", "Album"])
        let readsBefore = await fileSystem.reads
        let album = await disk.list(home + "/Cloud/Album", limit: 10, idleSeconds: 2)
        XCTAssertEqual(album.state, .notLoaded)
        let readsAfter = await fileSystem.reads
        XCTAssertEqual(readsAfter, readsBefore, "a folder marked not loaded is never listed")
        disk.clear()
        let cleared = await disk.list(home + "/Cloud/Album", limit: 10, idleSeconds: 2)
        XCTAssertEqual(cleared.state, .ok)
        let unmarked = await disk.item(at: home + "/Cloud/a.pdf")
        XCTAssertEqual(unmarked?.isDataless, false)
    }

    func testMarksOutsideTheAllowedPrefixAreIgnored() async throws {
        let (disk, _) = try await makeDisks()
        disk.markCloudOnly(home + "/Elsewhere/c.pdf")
        disk.markCloudOnly(home + "/Cloud2/d.pdf")
        disk.markNotLoaded(home + "/Elsewhere")
        disk.markNotLoaded(home + "/Cloud/../Elsewhere")
        disk.setDelay(5, under: home + "/Elsewhere")
        disk.setDelay(5, under: home)
        let start = Date()
        let file = await disk.item(at: home + "/Elsewhere/c.pdf")
        XCTAssertEqual(file?.isDataless, false)
        let lookalike = await disk.item(at: home + "/Cloud2/d.pdf")
        XCTAssertEqual(lookalike?.isDataless, false, "a folder whose name only starts the same isn't inside")
        let listing = await disk.list(home + "/Elsewhere", limit: 10, idleSeconds: 0.5)
        XCTAssertEqual(listing.state, .ok)
        XCTAssertEqual(listing.items.map(\.name), ["c.pdf"])
        XCTAssertLessThan(Date().timeIntervalSince(start), 3, "no delay was taken")
    }

    func testADelayedPlace() async throws {
        let (disk, _) = try await makeDisks()
        disk.setDelay(1, under: home + "/Cloud")
        var start = Date()
        let slow = await disk.list(home + "/Cloud", limit: 10, idleSeconds: 0.3)
        XCTAssertEqual(slow.state, .slow)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.29)
        start = Date()
        let late = await disk.list(home + "/Cloud", limit: 10, idleSeconds: 3)
        XCTAssertEqual(late.state, .ok, "within its limit a slow place still answers")
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.99)
        disk.setDelay(3, under: home + "/Cloud/Album")
        let silent = await disk.storage(of: home + "/Cloud/Album")
        XCTAssertFalse(silent.isResponding)
        XCTAssertEqual(silent.kind, .network)
        let path = await disk.canonicalPath(home + "/Cloud/Album")
        XCTAssertNil(path)
        disk.setDelay(0, under: home + "/Cloud/Album")
        disk.setDelay(0, under: home + "/Cloud")
        let quick = await disk.canonicalPath(home + "/Cloud/Album")
        XCTAssertEqual(quick, home + "/Cloud/Album")
    }
}
