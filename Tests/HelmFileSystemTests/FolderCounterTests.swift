import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmTestKit

/// Properties' count of what's inside a folder: every file and folder, hidden ones too, a package as one item with all
/// its bytes, links not followed, and a folder that can't be read noted rather than ending the count.
final class FolderCounterTests: XCTestCase {
    func testItCountsEverythingInsideAndNotesWhatItCouldntRead() async throws {
        let temp = try TempDirectory()
        let root = temp.url.appendingPathComponent("Measured")
        let closed = root.appendingPathComponent("Closed")
        defer { chmod(closed.path, 0o755); try? temp.remove() }
        let manager = FileManager.default
        for folder in ["sub/deeper", "Closed", "Tool.app/Contents"] {
            try manager.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for (path, text) in [("a.txt", "hello"), (".hidden", "abc"), ("sub/b.txt", "0123456789"),
                             ("sub/deeper/c.txt", "01234567890123456789"), ("Tool.app/Contents/Info.plist", "<plist>"),
                             ("Closed/x.txt", "not counted")] {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }
        // A link to a folder is one item, and what it points to isn't counted again.
        try manager.createSymbolicLink(at: root.appendingPathComponent("again"), withDestinationURL: root.appendingPathComponent("sub"))
        chmod(closed.path, 0)

        let final = await last(FolderCounter.count(folders: [root], in: LiveFileSystem()))
        XCTAssertEqual(final?.finished, true)
        let count = try XCTUnwrap(final?.count)
        // a.txt, .hidden, again, Tool.app, b.txt, c.txt; sub, deeper, Closed.
        XCTAssertEqual(count.files, 6)
        XCTAssertEqual(count.folders, 3)
        XCTAssertEqual(count.items, 9)
        XCTAssertEqual(count.unreadable, 1)
        XCTAssertEqual(count.notDownloaded, 0)
        XCTAssertTrue(count.isPartial)
        // 5 + 3 + 10 + 20 + 7, and the link's own few bytes.
        let link = try manager.attributesOfItem(atPath: root.appendingPathComponent("again").path)[.size] as? Int64 ?? 0
        XCTAssertEqual(count.bytes, 45 + link)
    }

    /// Several items: the files chosen count themselves, and each folder what's inside it.
    func testChosenFilesCountThemselvesAndAnUnreadableFolderIsNotedAtTheTop() async throws {
        let fs = InMemoryFileSystem()
        let folder = URL(fileURLWithPath: "/home/Project")
        try await fs.createDirectory(at: URL(fileURLWithPath: "/home"))
        try await fs.createDirectory(at: folder)
        try await fs.createFileExclusively(at: folder.appendingPathComponent("one.txt"), contents: Data("12345".utf8))
        let file = FileEntry(url: URL(fileURLWithPath: "/home/two.txt"), size: 7)
        let both = await last(FolderCounter.count(folders: [folder], files: [file], in: fs))?.count
        XCTAssertEqual(both?.files, 2)
        XCTAssertEqual(both?.folders, 0)
        XCTAssertEqual(both?.bytes, 12)
        let missing = await last(FolderCounter.count(folders: [URL(fileURLWithPath: "/home/Gone")], in: fs))?.count
        XCTAssertEqual(missing?.items, 0)
        XCTAssertEqual(missing?.unreadable, 1)
    }

    /// Running totals come while it counts, never going down, and the last one is the finished count.
    func testRunningTotalsOnlyGrowAndTheLastIsFinished() async throws {
        let fs = InMemoryFileSystem()
        let folder = URL(fileURLWithPath: "/home/Many")
        try await fs.createDirectory(at: URL(fileURLWithPath: "/home"))
        try await fs.createDirectory(at: folder)
        try await fs.seedFiles(in: folder, count: 3_000)
        var seen: [FolderCounter.Progress] = []
        for await progress in FolderCounter.count(folders: [folder], in: fs, every: .zero) { seen.append(progress) }
        XCTAssertGreaterThan(seen.count, 1)
        XCTAssertEqual(seen.filter(\.finished).count, 1)
        XCTAssertEqual(seen.last?.finished, true)
        XCTAssertEqual(seen.last?.count.files, 3_000)
        XCTAssertEqual(seen.map(\.count.items), seen.map(\.count.items).sorted())
    }

    private func last(_ stream: AsyncStream<FolderCounter.Progress>) async -> FolderCounter.Progress? {
        var latest: FolderCounter.Progress?
        for await progress in stream { latest = progress }
        return latest
    }
}
