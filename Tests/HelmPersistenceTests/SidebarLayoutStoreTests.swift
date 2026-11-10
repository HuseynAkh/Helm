import Foundation
import XCTest
import HelmCore
import HelmPersistence

/// sidebar.json, and bookmark moves and drops that name the bookmark they go before (P-188, P-306).
final class SidebarLayoutStoreTests: XCTestCase {
    private let favorites = ["recent-root", "home", "desktop", "documents", "downloads", "pictures", "music", "movies", "applications", "trash"]

    @MainActor func testLayoutSurvivesRelaunch() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = StoreLocation(directory: dir).sidebar
        XCTAssertEqual(url.lastPathComponent, "sidebar.json")
        let store = try await SidebarLayoutStore(url: url)
        XCTAssertTrue(store.layout.isDefault)
        store.update { $0.setHidden("music", true) }
        store.update { $0.move("trash", before: "recent-root", in: .favorites, natural: favorites) }
        try await store.flush()
        let reopened = try await SidebarLayoutStore(url: url)
        XCTAssertEqual(reopened.layout, store.layout)
        XCTAssertEqual(reopened.layout.hidden, ["music"])
        XCTAssertEqual(reopened.layout.favorites.first, "trash")
        reopened.restoreDefaults()
        XCTAssertTrue(reopened.layout.isDefault)
    }

    @MainActor func testChangesAreSentOnceAndOnlyForRealChanges() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for store in [SidebarLayoutStore(), try await SidebarLayoutStore(url: StoreLocation(directory: dir).sidebar)] {
            var sent: [SidebarLayout] = []
            _ = store.changes.subscribe { sent.append($0) }
            store.update { $0.setHidden("trash", true) }
            store.update { $0.setHidden("trash", true) }
            store.update { $0.move("home", before: "desktop", in: .favorites, natural: favorites) }
            store.restoreDefaults()
            store.restoreDefaults()
            XCTAssertEqual(sent, [SidebarLayout(hidden: ["trash"]), SidebarLayout()])
            XCTAssertTrue(store.layout.isDefault)
            try await store.flush()
        }
    }

    @MainActor func testADamagedFileIsKeptAsideAndTheDefaultLoads() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = StoreLocation(directory: dir).sidebar
        try Data("not json".utf8).write(to: url)
        let store = try await SidebarLayoutStore(url: url)
        XCTAssertTrue(store.layout.isDefault)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("sidebar.json.corrupt-") }
        XCTAssertEqual(backups.count, 1)
    }

    @MainActor func testANewerFileIsRefusedRatherThanOverwritten() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = StoreLocation(directory: dir).sidebar
        let newer = Data(#"{"schemaVersion":2,"items":{"hidden":["music"]}}"#.utf8)
        try newer.write(to: url)
        do {
            _ = try await SidebarLayoutStore(url: url)
            XCTFail("A newer schema loaded")
        } catch { XCTAssertEqual(error as? PersistenceError, .unsupportedVersion(2)) }
        XCTAssertEqual(try Data(contentsOf: url), newer)
    }

    @MainActor func testBookmarkMovesAndDropsNameTheBookmarkTheyGoBefore() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.appendingPathComponent("home")
        let store = try await BookmarkStore(url: StoreLocation(directory: dir).bookmarks, home: home)
        let folder = { (name: String) in URL(fileURLWithPath: "/work/\(name)") }
        for name in ["A", "H", "B", "C"] { store.add(folder(name), isDirectory: true) }
        func names() -> [String] { store.records.map { URL(fileURLWithPath: $0.path).lastPathComponent } }
        // With H hidden, dropping A between B and C lands it there, whatever H's position.
        store.move(path: folder("A").path, before: folder("C").path)
        XCTAssertEqual(names(), ["H", "B", "A", "C"])
        store.move(path: folder("C").path, before: nil)
        XCTAssertEqual(names(), ["H", "B", "A", "C"])
        store.move(path: folder("C").path, before: folder("H").path)
        XCTAssertEqual(names(), ["C", "H", "B", "A"])
        // An anchor that isn't a bookmark means the end; a path that isn't one moves nothing.
        store.move(path: folder("C").path, before: "/not/a/bookmark")
        XCTAssertEqual(names(), ["H", "B", "A", "C"])
        store.move(path: "/not/a/bookmark", before: folder("H").path)
        XCTAssertEqual(names(), ["H", "B", "A", "C"])
        XCTAssertTrue(store.insert(folder("D"), isDirectory: true, before: folder("B").path, date: Date()))
        XCTAssertTrue(store.insert(folder("E"), isDirectory: true, before: folder("B").path, date: Date()))
        XCTAssertTrue(store.insert(folder("F"), isDirectory: true, before: nil, date: Date()))
        XCTAssertFalse(store.insert(folder("F"), isDirectory: true, before: folder("H").path, date: Date()))
        XCTAssertEqual(names(), ["H", "D", "E", "B", "A", "C", "F"])
    }
}
