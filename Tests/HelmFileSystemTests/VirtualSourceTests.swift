import XCTest
import Foundation
import HelmCore
import HelmFileSystem

private actor RecordsFixture: RecentRecordsProviding, TrashOriginRecording {
    let records: [RecentRecord]
    init(records: [RecentRecord] = []) { self.records = records }
    func recentRecords() async -> [RecentRecord] { records }
    func record(_ items: [TrashedItem]) async {}
    func originalURL(forTrashed url: URL) async -> URL? { nil }
}
final class VirtualSourceTests: XCTestCase {
    func testTrashPermissionDeniedAndMissingRoots() async throws {
        let fs = InMemoryFileSystem()
        let home = URL(fileURLWithPath: "/home")
        try await fs.createDirectory(at: home)
        let trash = home.appendingPathComponent(".Trash")
        try await fs.createDirectory(at: trash)
        await fs.setFailure(.permissionDenied, at: trash)
        let source = TrashSource(fileSystem: fs, origins: RecordsFixture(), home: home, userID: "1000")
        do {
            for try await _ in source.load(.trash, options: LoadOptions()) {}
            XCTFail("Trash denial hidden")
        } catch { XCTAssertEqual(error as? FileSystemError, .permissionDenied) }
        await fs.setFailure(nil, at: trash)
        try await fs.removeItem(at: trash)
        var finished = false
        for try await event in source.load(.trash, options: LoadOptions()) {
            if case .finished = event { finished = true }
        }
        XCTAssertTrue(finished)
    }
    func testLoaderSortingRefreshAndDeniedCachedDirectory() async throws {
        let fs = InMemoryFileSystem()
        let root = URL(fileURLWithPath: "/root")
        try await fs.createDirectory(at: root)
        for name in ["file10", "file2", ".hidden"] {
            try await fs.createFileExclusively(at: root.appendingPathComponent(name), contents: Data())
        }
        let loader = DirectoryLoader(fileSystem: fs)
        let snapshot = try await loader.snapshot(.directory(root))
        XCTAssertEqual(snapshot.map(\.name), ["file2", "file10"])
        try await fs.removeItem(at: root.appendingPathComponent("file2"))
        let next = try await loader.refresh(location: .directory(root), changed: [root.appendingPathComponent("file2").path], current: snapshot)
        XCTAssertEqual(next.map(\.name), ["file10"])
        await fs.setFailure(.permissionDenied, at: root)
        do { _ = try await loader.snapshot(.directory(root)); XCTFail("Stale cache shown") }
        catch { XCTAssertEqual(error as? FileSystemError, .permissionDenied) }
    }
    func testRecentOrderPruningAndDeduplication() async throws {
        let fs = InMemoryFileSystem()
        for name in ["a", "b"] { try await fs.createFileExclusively(at: URL(fileURLWithPath: "/" + name), contents: Data()) }
        let records = RecordsFixture(records: [
            RecentRecord(path: "/a", lastAccessedAt: Date(timeIntervalSince1970: 1), kind: .regular),
            RecentRecord(path: "/b", lastAccessedAt: Date(timeIntervalSince1970: 2), kind: .regular),
            RecentRecord(path: "/b", lastAccessedAt: Date(timeIntervalSince1970: 0), kind: .regular),
            RecentRecord(path: "/missing", lastAccessedAt: Date(), kind: .regular)
        ])
        var entries: [FileEntry] = []
        for try await event in RecentSource(records: records, fileSystem: fs).load(.recent, options: LoadOptions()) {
            if case .batch(let batch) = event { entries += batch }
        }
        XCTAssertEqual(entries.map(\.name), ["b", "a"])
    }
}
