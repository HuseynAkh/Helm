import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmTestKit

/// Permissions hunt: a folder that can't be opened is explained by what's really wrong. A link that leads nowhere
/// isn't a permissions problem, and a folder on a disk that's gone says the disk was disconnected.
final class HuntPermissionsLoadingTests: XCTestCase {
    private let generation = Generation(rawValue: 3)
    private let brokenLink = LoadError.other("The item this link points to can’t be found.")

    private func failure(_ location: URL, in fileSystem: any FileSystem) async -> LoadError? {
        let pipeline = DirectoryLoadPipeline(fileSystem: fileSystem)
        var last: TabAction?
        for await action in await pipeline.load(.directory(location), generation: generation) { last = action }
        withExtendedLifetime(pipeline) {}
        guard case .loadFailed(_, let error)? = last else { return nil }
        return ContentStatePresentation.plain(error)
    }

    // MARK: Links that lead nowhere (permissions-7)

    func testALinkThatLeadsNowhereIsNotARefusal() async throws {
        let fs = InMemoryFileSystem()
        let home = URL(fileURLWithPath: "/home", isDirectory: true)
        try await fs.createDirectory(at: home)
        let gone = home.appendingPathComponent("Old Projects", isDirectory: true)
        try await fs.createSymbolicLink(at: gone, destination: URL(fileURLWithPath: "/Volumes/Unplugged/Projects"))
        let failed = await failure(gone, in: fs)
        XCTAssertEqual(failed, brokenLink)
        XCTAssertNotEqual(failed, .permissionDenied)
    }

    /// On the Mac's own disk: a link to a folder that's gone, and one that points at itself. access(2) answers ENOENT
    /// and ELOOP for them, which used to read as a refusal.
    func testRealLinksThatLeadNowhereAreNotRefusals() async throws {
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        let gone = temp.url.appendingPathComponent("Old Projects")
        let loop = temp.url.appendingPathComponent("Loop")
        XCTAssertEqual(symlink(temp.url.appendingPathComponent("Unplugged Disk/Projects").path, gone.path), 0)
        XCTAssertEqual(symlink("Loop", loop.path), 0)
        let fs = LiveFileSystem()
        let gonePlace = await failure(gone, in: fs)
        let loopPlace = await failure(loop, in: fs)
        XCTAssertEqual(gonePlace, brokenLink)
        XCTAssertEqual(loopPlace, brokenLink)
        // The card says what's wrong in plain words, with no owner or permissions in it.
        let card = ContentStatePresentation.failure(brokenLink, attempted: .directory(loop), home: temp.url, fullDiskAccess: .denied)
        XCTAssertEqual(card?.title, "Helm couldn’t open “Loop”")
        XCTAssertEqual(card?.message, "The item this link points to can’t be found.")
        XCTAssertEqual(card?.buttons.map(\.title), ["Try Again"])
    }

    // MARK: A disk that's gone (permissions-4)

    func testAFolderOnADiskThatIsGoneSaysTheDiskWasDisconnected() async throws {
        let fs = InMemoryFileSystem()
        let volumes = URL(fileURLWithPath: "/Volumes", isDirectory: true)
        let disk = volumes.appendingPathComponent("Backup", isDirectory: true)
        for folder in [volumes, disk, URL(fileURLWithPath: "/Users", isDirectory: true)] { try await fs.createDirectory(at: folder) }
        // The disk is there, but the folder isn't: moved or deleted, as before.
        let projects = disk.appendingPathComponent("Projects", isDirectory: true)
        let missing = await failure(projects, in: fs)
        XCTAssertEqual(missing, .notFound)
        // The disk itself is gone: ejected, unplugged, or its server went away. Its own folder and those inside say so.
        try await fs.removeItem(at: disk)
        let inside = await failure(projects.appendingPathComponent("2026", isDirectory: true), in: fs)
        let ownFolder = await failure(disk, in: fs)
        XCTAssertEqual(inside, .volumeUnmounted)
        XCTAssertEqual(ownFolder, .volumeUnmounted)
        // A folder on the startup disk is just gone.
        let elsewhere = await failure(URL(fileURLWithPath: "/Users/Gone", isDirectory: true), in: fs)
        XCTAssertEqual(elsewhere, .notFound)
    }

    /// The monitor's reload, as after an eject, reads the folder the same way, so its card says the same.
    func testTheMonitorsReloadSaysTheDiskWasDisconnectedToo() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: URL(fileURLWithPath: "/Volumes", isDirectory: true))
        let projects = URL(fileURLWithPath: "/Volumes/Backup/Projects", isDirectory: true)
        do {
            _ = try await DirectoryLoader(fileSystem: fs).snapshot(.directory(projects))
            XCTFail("a folder on a disk that's gone can't be listed")
        } catch {
            XCTAssertEqual(error as? LoadError, .volumeUnmounted)
        }
    }
}
