import Foundation
import XCTest
import HelmCore
@testable import HelmPersistence

/// The stores keep less: a trashed item's record has a limit and goes when the item leaves the Trash, a session
/// Settings doesn't want is deleted, and the apps you've used can be forgotten.
@MainActor final class PrivacyStoreTests: XCTestCase {
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        super.tearDown()
    }
    private func folder() throws -> URL {
        let url = try temporaryStoreDirectory()
        folders.append(url)
        return url
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: trash-origins.json

    /// While Helm runs, no record goes to make room: Undo of a Move to Trash bigger than the limit needs every one.
    /// The next launch keeps the newest `limit`.
    func testTrashRecordsPastTheLimitGoAtTheNextLaunchOldestFirst() async throws {
        let url = try folder().appendingPathComponent("trash-origins.json")
        let store = try await TrashOriginStore(url: url)
        let trash = URL(fileURLWithPath: "/Users/someone/.Trash", isDirectory: true)
        let documents = URL(fileURLWithPath: "/Users/someone/Documents", isDirectory: true)
        for index in 0..<(TrashOriginStore.limit + 5) {
            store.record([TrashedItem(trashedURL: trash.appendingPathComponent("item \(index)"),
                                      originalURL: documents.appendingPathComponent("item \(index)"))],
                         at: Date(timeIntervalSince1970: Double(index)))
        }
        XCTAssertEqual(store.records.count, TrashOriginStore.limit + 5)
        let first = await store.originalURL(forTrashed: trash.appendingPathComponent("item 0"))
        XCTAssertEqual(first, documents.appendingPathComponent("item 0"), "Undo still finds the first item of a big Move to Trash")
        try await store.flush()
        let next = try await TrashOriginStore(url: url)
        XCTAssertEqual(next.records.count, TrashOriginStore.limit)
        let oldest = await next.originalURL(forTrashed: trash.appendingPathComponent("item 4"))
        let kept = await next.originalURL(forTrashed: trash.appendingPathComponent("item 5"))
        let newest = await next.originalURL(forTrashed: trash.appendingPathComponent("item \(TrashOriginStore.limit + 4)"))
        XCTAssertNil(oldest, "the oldest records go first")
        XCTAssertEqual(kept, documents.appendingPathComponent("item 5"))
        XCTAssertEqual(newest, documents.appendingPathComponent("item \(TrashOriginStore.limit + 4)"))
        try await next.flush()
    }

    /// A list saved before there was a limit is trimmed the first time it's read.
    func testAListSavedBeforeTheLimitIsTrimmedWhenRead() async throws {
        let url = try folder().appendingPathComponent("trash-origins.json")
        let saved = (0..<1_200).map {
            TrashOriginRecord(trashedPath: "/Users/someone/.Trash/\($0)", originalPath: "/Users/someone/\($0)",
                              trashedAt: Date(timeIntervalSince1970: Double($0)))
        }
        try JSONEncoder().encode(VersionedDocument(items: saved)).write(to: url)
        let store = try await TrashOriginStore(url: url)
        XCTAssertEqual(store.records.count, TrashOriginStore.limit)
        XCTAssertFalse(store.records.contains { $0.trashedPath == "/Users/someone/.Trash/199" })
        XCTAssertTrue(store.records.contains { $0.trashedPath == "/Users/someone/.Trash/200" })
        try await store.flush()
        let reopened = try await TrashOriginStore(url: url)
        XCTAssertEqual(reopened.records.count, TrashOriginStore.limit)
    }

    /// A record made while the item is in the Trash still matches its place after the item has gone. The temporary
    /// folder is under /private, which standardizedFileURL leaves out only while the item exists.
    func testARecordStillMatchesItsPlaceOnceTheItemHasGone() async throws {
        let root = try folder()
        let long = URL(fileURLWithPath: (root.path.hasPrefix("/private/") ? "" : "/private") + root.path, isDirectory: true)
        guard ["/private/tmp/", "/private/var/"].contains(where: long.path.hasPrefix) else {
            throw XCTSkip("the temporary folder isn't under /private/tmp or /private/var")
        }
        let trash = long.appendingPathComponent(".Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let first = trash.appendingPathComponent("first.txt"), second = trash.appendingPathComponent("second.txt")
        for item in [first, second] { try Data("x".utf8).write(to: item) }
        let store = try await TrashOriginStore(url: root.appendingPathComponent("trash-origins.json"))
        store.record([TrashedItem(trashedURL: first, originalURL: long.appendingPathComponent("first.txt")),
                      TrashedItem(trashedURL: second, originalURL: long.appendingPathComponent("second.txt"))], at: Date())
        for item in [first, second] { try FileManager.default.removeItem(at: item) }
        let original = await store.originalURL(forTrashed: first)
        XCTAssertEqual(original?.lastPathComponent, "first.txt")
        store.removeOrigins(for: [first])
        XCTAssertEqual(store.records.map { URL(fileURLWithPath: $0.trashedPath).lastPathComponent }, ["second.txt"])
        store.removeOrigins(for: [URL(fileURLWithPath: String(second.path.dropFirst("/private".count)))])
        XCTAssertTrue(store.records.isEmpty, "/tmp and /private/tmp are one place")
        try await store.flush()
    }

    // MARK: session.json

    /// Reopen windows and tabs off: the session is forgotten and its file deleted straight away. Saving then writes
    /// nothing until there's a session to keep again.
    func testARemovedSessionIsDeletedAndStaysDeletedUntilTheNextChange() async throws {
        let url = try folder().appendingPathComponent("session.json")
        let store = try await SessionStore(url: url)
        let windows = [SessionWindow(frameAutosaveName: "HelmMainWindow", tabs: [SessionTab(location: .recent)])]
        store.replace(windows: windows)
        try await store.flush()
        XCTAssertTrue(exists(url))
        store.remove()
        XCTAssertTrue(store.windows.isEmpty)
        let deadline = Date().addingTimeInterval(3)
        while exists(url) && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertFalse(exists(url), "the file goes without waiting for quit")
        try await store.flush()
        XCTAssertFalse(exists(url), "saving at quit doesn't write it again")
        store.remove()
        try await store.flush()
        XCTAssertFalse(exists(url), "removing it twice is fine")
        store.replace(windows: windows)
        try await store.flush()
        let reopened = try await SessionStore(url: url)
        XCTAssertEqual(reopened.windows, windows, "a new session is kept again")
        // With no file there to begin with, as when Helm starts with the switch off, removing is fine too.
        let fresh = try await SessionStore(url: try folder().appendingPathComponent("session.json"))
        fresh.remove()
        try await fresh.flush()
    }

    // MARK: open-with.json

    func testTheAppsYouveUsedCanBeForgotten() async throws {
        let url = try folder().appendingPathComponent("open-with.json")
        let store = try await OpenWithStore(url: url)
        store.recordUse(of: "/System/Applications/TextEdit.app", for: "public.plain-text", at: Date())
        store.clear()
        XCTAssertTrue(store.records.isEmpty)
        try await store.flush()
        let reopened = try await OpenWithStore(url: url)
        XCTAssertTrue(reopened.records.isEmpty)
        let memory = OpenWithStore()
        memory.recordUse(of: "/System/Applications/TextEdit.app", for: "public.plain-text", at: Date())
        memory.clear()
        XCTAssertTrue(memory.records.isEmpty)
    }
}
