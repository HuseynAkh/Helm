import Foundation
import XCTest
import HelmCore
@testable import HelmFileSystem

/// The in-memory disk standing in for a cloud: with downloads off, what would need an item's bytes or a folder's
/// names from the cloud fails as macOS fails it, and nothing is read. Without downloads off it behaves as before.
final class InMemoryDownloadsOffTests: XCTestCase {
    private let cloud = URL(fileURLWithPath: "/home/helm/Library/CloudStorage/Dropbox")
    private let local = URL(fileURLWithPath: "/home/helm/Downloads")

    /// A cloud folder with an evicted file, a folder holding one, and a folder whose names aren't loaded.
    private func makeDisk(volumes: [URL: String] = [:]) async throws -> InMemoryFileSystem {
        let disk = InMemoryFileSystem(volumeIDs: volumes)
        for folder in ["/home", "/home/helm", "/home/helm/Library", "/home/helm/Library/CloudStorage", cloud.path, local.path,
                       cloud.path + "/Album", cloud.path + "/Remote"] {
            try await disk.createDirectory(at: URL(fileURLWithPath: folder))
        }
        try await disk.createFileExclusively(at: cloud.appendingPathComponent("Report.pdf"), contents: Data("report".utf8))
        try await disk.createFileExclusively(at: cloud.appendingPathComponent("Here.txt"), contents: Data("here".utf8))
        try await disk.createFileExclusively(at: cloud.appendingPathComponent("Album/a.jpg"), contents: Data("jpg".utf8))
        try await disk.createFileExclusively(at: cloud.appendingPathComponent("Remote/b.txt"), contents: Data("b".utf8))
        await disk.setCloudAvailability(.evicted, at: cloud.appendingPathComponent("Report.pdf"))
        await disk.setCloudAvailability(.evicted, at: cloud.appendingPathComponent("Album/a.jpg"))
        await disk.setCloudAvailability(.evicted, at: cloud.appendingPathComponent("Remote"))
        return disk
    }

    private func expectNotDownloaded(_ work: () async throws -> Void, _ message: String) async {
        do { try await work(); XCTFail(message) } catch { XCTAssertEqual(error as? FileSystemError, .notDownloaded, message) }
    }

    func testCopyingAnEvictedItemWithDownloadsOffThrowsAndReadsNothing() async throws {
        let disk = try await makeDisk()
        let report = cloud.appendingPathComponent("Report.pdf"), album = cloud.appendingPathComponent("Album")
        await DatalessGuard.off {
            await expectNotDownloaded({ try await disk.copyItem(at: report, to: self.local.appendingPathComponent("Report.pdf")) },
                                      "a copy of a file that isn't downloaded")
            await expectNotDownloaded({ try await disk.copyItem(at: album, to: self.local.appendingPathComponent("Album")) },
                                      "a copy of a folder holding one")
            // The conditional change that Apply uses fails the same way.
            if let evidence = try? await disk.mutationPrecondition(at: report) {
                await expectNotDownloaded({ _ = try await disk.mutate(.copy(to: self.local.appendingPathComponent("R.pdf")), source: report,
                                                                     requiring: evidence) }, "a conditional copy")
            } else { XCTFail("no evidence") }
        }
        let reads = await disk.reads
        XCTAssertEqual(reads, [], "nothing was read")
        let copied = await disk.exists(local.appendingPathComponent("Report.pdf"))
        let copiedFolder = await disk.exists(local.appendingPathComponent("Album"))
        XCTAssertFalse(copied)
        XCTAssertFalse(copiedFolder, "not even the folder was made")
        // A downloaded file in the same cloud folder copies as ever, and its bytes are read.
        try await DatalessGuard.off { try await disk.copyItem(at: cloud.appendingPathComponent("Here.txt"), to: local.appendingPathComponent("Here.txt")) }
        let afterCopy = await disk.reads
        XCTAssertEqual(afterCopy, [cloud.appendingPathComponent("Here.txt").path])
    }

    func testMovingAnEvictedItemToAnotherVolumeWithDownloadsOffThrows() async throws {
        let external = URL(fileURLWithPath: "/Volumes/Backup")
        let disk = try await makeDisk(volumes: [external: "backup"])
        try await disk.createDirectory(at: URL(fileURLWithPath: "/Volumes"))
        try await disk.createDirectory(at: external)
        let report = cloud.appendingPathComponent("Report.pdf")
        await DatalessGuard.off {
            await expectNotDownloaded({ try await disk.moveItem(at: report, to: external.appendingPathComponent("Report.pdf")) },
                                      "a move to another volume")
            if let evidence = try? await disk.mutationPrecondition(at: report) {
                await expectNotDownloaded({ _ = try await disk.mutate(.move(to: external.appendingPathComponent("R.pdf")), source: report,
                                                                     requiring: evidence) }, "a conditional move to another volume")
            } else { XCTFail("no evidence") }
        }
        let stayed = await disk.exists(report)
        XCTAssertTrue(stayed)
        let reads = await disk.reads
        XCTAssertEqual(reads, [])
        // Within its own volume a move only renames it, so nothing needs its bytes and it is still not downloaded.
        let renamed = cloud.appendingPathComponent("Old Report.pdf")
        try await DatalessGuard.off { try await disk.moveItem(at: report, to: renamed) }
        let entry = try await disk.entry(at: renamed)
        XCTAssertEqual(entry.cloudAvailability, .evicted)
        let afterRename = await disk.reads
        XCTAssertEqual(afterRename, [])
    }

    func testListingAFolderThatIsNotLoadedWithDownloadsOffThrowsAndReadsNothing() async throws {
        let disk = try await makeDisk()
        let remote = cloud.appendingPathComponent("Remote")
        await DatalessGuard.off {
            await expectNotDownloaded({ for try await _ in disk.enumerate(remote, options: EnumerationOptions(includeHidden: true)) {} },
                                      "listing a folder that isn't loaded")
            await expectNotDownloaded({ _ = try await disk.childNames(of: remote) }, "its names")
        }
        let reads = await disk.reads
        XCTAssertEqual(reads, [])
        // Its own details are free: a folder that isn't loaded is still there, marked.
        let entry = try await DatalessGuard.off { try await disk.entry(at: remote) }
        XCTAssertEqual(entry.cloudAvailability, .evicted)
        XCTAssertEqual(entry.kind, .directory)
    }

    func testWithoutDownloadsOffEverythingBehavesAsBefore() async throws {
        let disk = try await makeDisk()
        let report = cloud.appendingPathComponent("Report.pdf"), remote = cloud.appendingPathComponent("Remote")
        try await disk.copyItem(at: report, to: local.appendingPathComponent("Report.pdf"))
        try await disk.copyItem(at: cloud.appendingPathComponent("Album"), to: local.appendingPathComponent("Album"))
        let names = try await disk.childNames(of: remote)
        XCTAssertEqual(names, ["b.txt"])
        let copied = try await disk.entry(at: local.appendingPathComponent("Report.pdf"))
        XCTAssertEqual(copied.size, 6)
        XCTAssertEqual(copied.cloudAvailability, .unknown, "the copy is an ordinary local file")
        let reads = await disk.reads
        XCTAssertEqual(reads, [report.path, cloud.appendingPathComponent("Album").path, cloud.appendingPathComponent("Album/a.jpg").path,
                               remote.path])
    }

    func testAChildWhoseDetailsCantBeReadIsSkippedOnlyWithDownloadsOff() async throws {
        let disk = try await makeDisk()
        await disk.setFailure(.permissionDenied, at: cloud.appendingPathComponent("Here.txt"))
        let counted = DatalessGuard.SkippedChildren()
        let names = try await DatalessGuard.off {
            try await DatalessGuard.$skippedChildren.withValue(counted) { try await disk.childNames(of: self.cloud) }
        }
        XCTAssertEqual(names, ["Album", "Remote", "Report.pdf"])
        XCTAssertEqual(counted.count, 1)
        let before = try await disk.childNames(of: cloud)
        XCTAssertEqual(before, ["Album", "Here.txt", "Remote", "Report.pdf"], "without downloads off the listing is as it was")
    }

    func testTrashRefusedUnderAPlaceAndAPlaceThatIsSlow() async throws {
        let disk = try await makeDisk()
        await disk.setTrashUnsupported(under: cloud)
        do { _ = try await disk.trashItem(at: cloud.appendingPathComponent("Here.txt")); XCTFail("trashed") }
        catch { XCTAssertEqual(error as? FileSystemError, .unsupported) }
        let kept = await disk.exists(cloud.appendingPathComponent("Here.txt"))
        XCTAssertTrue(kept)
        try await disk.createFileExclusively(at: local.appendingPathComponent("x.txt"), contents: Data())
        let trashed = try await disk.trashItem(at: local.appendingPathComponent("x.txt"))
        XCTAssertNotNil(trashed, "elsewhere the Trash works")

        await disk.setDelay(0.3, under: cloud)
        let start = Date()
        _ = try await disk.entry(at: cloud.appendingPathComponent("Here.txt"))
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.29)
        let quick = Date()
        _ = try await disk.entry(at: local)
        XCTAssertLessThan(Date().timeIntervalSince(quick), 0.25, "only the slow place waits")
    }
}
