import XCTest
import HelmCore
import HelmPersistence

final class StoresTests: XCTestCase {
    @MainActor func testTrashOriginsAndStoreLocations() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let location = StoreLocation(directory: dir)
        XCTAssertEqual([location.stars, location.bookmarks, location.recent, location.session, location.trashOrigins].map(\.lastPathComponent),
                       ["stars.json", "bookmarks.json", "recent.json", "session.json", "trash-origins.json"])
        let store = try await TrashOriginStore(url: location.trashOrigins)
        let trash = URL(fileURLWithPath: "/home/.Trash/a")
        let original = URL(fileURLWithPath: "/home/a")
        await store.record([TrashedItem(trashedURL: trash, originalURL: original)])
        let date = Date(timeIntervalSinceReferenceDate: 42)
        store.record([TrashedItem(trashedURL: trash, originalURL: original)], at: date)
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.trashedAt, date)
        try await store.flush()
        let restored = try await TrashOriginStore(url: location.trashOrigins)
        let found = await restored.originalURL(forTrashed: trash)
        XCTAssertEqual(found, original)
        let unknown = await restored.originalURL(forTrashed: URL(fileURLWithPath: "/unknown"))
        XCTAssertNil(unknown)
        restored.removeOrigins(for: [trash]); try await restored.flush()
        XCTAssertTrue(restored.records.isEmpty)
    }

    @MainActor func testSettingsUseMemoryDefaultsAndPublishCommittedState() async throws {
        let memory = MemoryDefaults()
        memory.values["helm.gridIconSize"] = 64.0
        memory.values["helm.confirmBeforeTrash"] = true
        let store = SettingsStore(storage: memory)
        XCTAssertEqual(store.snapshot.double(.gridIconSize), 64)
        XCTAssertTrue(store.snapshot.bool(.confirmBeforeTrash))
        XCTAssertEqual(store.snapshot.integer(.maxCachedIcons), 800)
        var count = 0
        let token = store.changes.subscribe { snapshot in
            XCTAssertEqual(snapshot, store.snapshot); count += 1
        }
        store.set(.integer(1), for: .searchResultLimit)
        store.set(.integer(1), for: .searchResultLimit)
        XCTAssertEqual(store.snapshot.integer(.searchResultLimit), 50)
        XCTAssertEqual(count, 1)
        store.changes.cancel(token)
        store.set(.bool(true), for: .showHiddenFiles)
        XCTAssertEqual(count, 1)
    }
    @MainActor func testStarsBookmarksAndSessionRoundTrips() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = URL(fileURLWithPath: "/Users/test")
        let offline = URL(fileURLWithPath: "/Volumes/offline/folder")
        let starURL = dir.appendingPathComponent("stars.json")
        let stars = try await StarStore(url: starURL)
        stars.star(offline); stars.star(offline)
        XCTAssertEqual(stars.records.count, 1)
        stars.toggle(offline); XCTAssertFalse(stars.isStarred(offline))
        stars.toggle(offline); try await stars.flush()
        let restoredStars = try await StarStore(url: starURL)
        XCTAssertTrue(restoredStars.isStarred(offline))
        let bookmarkURL = dir.appendingPathComponent("bookmarks.json")
        let bookmarks = try await BookmarkStore(url: bookmarkURL, home: home)
        XCTAssertFalse(bookmarks.add(offline, isDirectory: false))
        XCTAssertTrue(bookmarks.add(offline, isDirectory: true))
        XCTAssertFalse(bookmarks.add(offline, isDirectory: true))
        XCTAssertTrue(bookmarks.add(home, isDirectory: true))
        try await bookmarks.flush()
        let restored = try await BookmarkStore(url: bookmarkURL, home: home)
        XCTAssertEqual(Set(restored.records.map(\.path)), Set([home.path, offline.path]))
        restored.remove(path: home.path); try await restored.flush()
        XCTAssertEqual(restored.records.count, 1)
        let sessionURL = dir.appendingPathComponent("session.json")
        let session = try await SessionStore(url: sessionURL)
        let window = SessionWindow(frameAutosaveName: "HelmMainWindow", tabs: [
            SessionTab(location: .recent), SessionTab(location: .directory(home), viewMode: .list, showHidden: true)
        ], activeTabIndex: 99)
        XCTAssertEqual(window.activeTabIndex, 1)
        session.replace(windows: [window]); try await session.flush()
        let restoredSession = try await SessionStore(url: sessionURL)
        XCTAssertEqual(restoredSession.windows, [window])
    }
    /// A tab left in Recent saves its Last Opened order and gets it back; the file names it only beside a stand-in
    /// that builds from before Last Opened can read.
    @MainActor func testASessionLeftInRecentKeepsLastOpened() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("session.json")
        let session = try await SessionStore(url: url)
        let window = SessionWindow(frameAutosaveName: "HelmMainWindow", tabs: [
            SessionTab(location: .recent, viewMode: .list, sort: ItemSort(field: .lastOpened, ascending: false))
        ])
        session.replace(windows: [window]); try await session.flush()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.replacingOccurrences(of: " ", with: "").contains(#""field":"lastOpened""#))
        let restored = try await SessionStore(url: url)
        XCTAssertEqual(restored.windows, [window])
    }
    @MainActor func testRecentCapsNewestWinsAndOfflineRecordsSurvive() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("recent.json")
        let recent = try await RecentStore(url: url)
        for index in 0..<310 {
            recent.recordAccess(to: URL(fileURLWithPath: "/missing/\(index)"), at: Date(timeIntervalSince1970: Double(index)))
        }
        recent.recordAccess(to: URL(fileURLWithPath: "/missing/309"), at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(recent.records.count, 300)
        XCTAssertEqual(recent.records.first?.path, "/missing/309")
        let displayed = await recent.recentRecords()
        XCTAssertEqual(displayed.count, 180)
        try await recent.flush()
        let restored = try await RecentStore(url: url)
        XCTAssertEqual(restored.records, recent.records)
        restored.clear(); try await restored.flush()
        XCTAssertTrue(restored.records.isEmpty)
    }
}
