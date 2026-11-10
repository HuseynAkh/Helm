import XCTest
import HelmCore
@testable import HelmPersistence

/// Hunt: bookmarks.json and stars.json follow items renamed or moved in Helm, and keep them after a relaunch.
@MainActor final class HuntSidebarSettingsStoreTests: XCTestCase {
    /// Spelled out in full, so making the URLs doesn't ask the disk about paths that aren't there.
    private func move(_ from: String, _ to: String) -> PathMove {
        PathMove(from: URL(fileURLWithPath: from, isDirectory: false), to: URL(fileURLWithPath: to, isDirectory: false))
    }

    func testBookmarksFollowARenamedFolderInTheirPlace() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("bookmarks.json")
        let store = try await BookmarkStore(url: file, home: URL(fileURLWithPath: "/home"))
        let added = Date(timeIntervalSince1970: 1_000)
        for name in ["Alpha", "Reports", "Zeta"] { store.add(URL(fileURLWithPath: "/home/\(name)"), isDirectory: true, at: added) }
        var sent: [[String]] = []
        let token = store.changes.subscribe { sent.append($0.map(\.name)) }
        defer { store.changes.cancel(token) }
        store.relocate(PathMoves([move("/home/Reports", "/home/Reports 2026")]))
        XCTAssertEqual(store.records.map(\.path), ["/home/Alpha", "/home/Reports 2026", "/home/Zeta"])
        XCTAssertEqual(store.records.map(\.name), ["Alpha", "Reports 2026", "Zeta"])
        XCTAssertEqual(store.records[1].addedAt, added)
        XCTAssertEqual(sent, [["Alpha", "Reports 2026", "Zeta"]])
        // Nothing of ours moved: nothing changes, and nothing is sent.
        store.relocate(PathMoves([move("/elsewhere/Reports", "/elsewhere/Other")]))
        XCTAssertEqual(sent.count, 1)
        try await store.flush()
        let reopened = try await BookmarkStore(url: file, home: URL(fileURLWithPath: "/home"))
        XCTAssertEqual(reopened.records.map(\.path), ["/home/Alpha", "/home/Reports 2026", "/home/Zeta"])
    }

    func testStarsFollowAMovedFolderAndTheFilesInIt() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("stars.json")
        let store = try await StarStore(url: file)
        let starred = Date(timeIntervalSince1970: 2_000)
        store.star(URL(fileURLWithPath: "/home/Documents/Reports/q1.txt"), at: starred)
        store.star(URL(fileURLWithPath: "/home/Documents/alpha.md"), at: starred)
        store.relocate(PathMoves([move("/home/Documents/Reports", "/home/Desktop/Reports"),
                                  move("/home/Documents/alpha.md", "/home/Documents/beta.md")]))
        XCTAssertEqual(store.records.map(\.path), ["/home/Desktop/Reports/q1.txt", "/home/Documents/beta.md"])
        XCTAssertEqual(store.records.map(\.addedAt), [starred, starred])
        XCTAssertTrue(store.isStarred(URL(fileURLWithPath: "/home/Documents/beta.md")))
        XCTAssertFalse(store.isStarred(URL(fileURLWithPath: "/home/Documents/alpha.md")))
        try await store.flush()
        let reopened = try await StarStore(url: file)
        XCTAssertEqual(reopened.records.map(\.path), ["/home/Desktop/Reports/q1.txt", "/home/Documents/beta.md"])
    }
}
