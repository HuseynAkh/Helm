import Foundation
import XCTest
import HelmCore
@testable import HelmFileSystem
import HelmTestKit

/// A folder reached through a symbolic link: Go › Downloads when Downloads is a link to another disk, a linked
/// folder another app asks Helm to open, or a file inside one that it asks Helm to show. Each has to list the folder
/// the link points at, as Finder does, rather than fail with "Not a directory".
final class HuntNavigationSymlinkTests: XCTestCase {
    private var temp: TempDirectory!
    private var real: URL!
    private var link: URL!

    override func setUpWithError() throws {
        temp = try TempDirectory()
        real = temp.url.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try Data("x".utf8).write(to: real.appendingPathComponent("inside.txt"))
        link = temp.url.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    }
    override func tearDownWithError() throws { try temp?.remove() }

    func testLoadingAFolderThroughALinkListsWhatsInside() async throws {
        let pipeline = DirectoryLoadPipeline(fileSystem: LiveFileSystem())
        var last: TabAction?
        for await action in await pipeline.load(.directory(link), generation: Generation(rawValue: 1)) { last = action }
        guard case .loadFinished(_, let snapshot)? = last else {
            return XCTFail("The folder behind the link didn't open: \(String(describing: last))")
        }
        XCTAssertEqual(snapshot.sortedEntries.map(\.name), ["inside.txt"])
    }

    func testListingALinkedFolderGivesItsFiles() async throws {
        var entries: [FileEntry] = []
        do {
            for try await batch in LiveFileSystem().enumerate(link) { entries += batch }
        } catch {
            return XCTFail("Listing the linked folder failed: \(error)")
        }
        XCTAssertEqual(entries.map(\.name), ["inside.txt"])
        // Each item is the linked folder's own: a linked folder open in the list beside the real one never shares rows.
        XCTAssertEqual(entries.map { PathSpelling.standardPath($0.url.deletingLastPathComponent()) }, [PathSpelling.standardPath(link)])
        XCTAssertEqual(entries.first?.kind, .regular)
    }

    func testAFolderThatIsntALinkListsAsBefore() async throws {
        var entries: [FileEntry] = []
        for try await batch in LiveFileSystem().enumerate(real) { entries += batch }
        XCTAssertEqual(entries.map(\.name), ["inside.txt"])
        XCTAssertNil(LiveFileSystem.linkedFolder(real))
        XCTAssertEqual(LiveFileSystem.linkedFolder(link).map(PathSpelling.standardPath), PathSpelling.standardPath(real))
    }

    func testALinkToNothingStillFails() async throws {
        let dangling = temp.url.appendingPathComponent("Dangling", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: temp.url.appendingPathComponent("Nowhere"))
        do {
            for try await _ in LiveFileSystem().enumerate(dangling) {}
            XCTFail("A link to nothing listed something")
        } catch {}
    }
}
