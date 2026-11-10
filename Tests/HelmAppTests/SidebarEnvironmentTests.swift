import Foundation
import XCTest
import HelmCore
import HelmPersistence
@testable import HelmApp

/// sidebar.json is loaded, flushed at quit and reported like Helm's other documents (OK2-9, F-068).
final class SidebarEnvironmentTests: XCTestCase {
    private func directories() throws -> AppDirectories {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Helm-sidebar-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return AppDirectories(home: root.appendingPathComponent("home"), applicationSupport: root)
    }
    @MainActor private func live(_ directories: AppDirectories) async throws -> AppEnvironment {
        try await AppEnvironment.live(directories: directories, settingsStorage: SidebarTestSettings(), legacyReader: SidebarTestLegacy())
    }

    @MainActor func testTheLayoutLivesInItsOwnFileAndComesBack() async throws {
        let directories = try directories()
        defer { try? FileManager.default.removeItem(at: directories.applicationSupport) }
        let env = try await live(directories)
        XCTAssertTrue(env.loadFailures.isEmpty)
        env.sidebarLayout.update { $0.setHidden("music", true) }
        let failures = await env.flushStores()
        XCTAssertEqual(failures, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: StoreLocation(directory: directories.applicationSupport).sidebar.path))
        let reloaded = try await live(directories)
        XCTAssertEqual(reloaded.sidebarLayout.layout.hidden, ["music"])
        // The memory-only environment starts with every row shown.
        let memory = try await AppEnvironment.test()
        XCTAssertTrue(memory.sidebarLayout.layout.isDefault)
    }

    @MainActor func testAFileHelmCantReadIsReportedAndLeftAlone() async throws {
        let directories = try directories()
        defer { try? FileManager.default.removeItem(at: directories.applicationSupport) }
        let url = StoreLocation(directory: directories.applicationSupport).sidebar
        let newer = Data(#"{"schemaVersion":2,"items":{}}"#.utf8)
        try newer.write(to: url)
        let env = try await live(directories)
        XCTAssertEqual(env.loadFailures.map(\.document), ["sidebar"])
        // Changes still work for the session, in memory.
        env.sidebarLayout.update { $0.setHidden("trash", true) }
        XCTAssertEqual(env.sidebarLayout.layout.hidden, ["trash"])
        let failures = await env.flushStores()
        XCTAssertEqual(failures, [])
        XCTAssertEqual(try Data(contentsOf: url), newer)
    }

    /// However a star or a bookmark goes, sidebar.json forgets its row: where it was and whether it was hidden. Starred
    /// and bookmarked again, both are on show, the starred item in its natural place. A drive that's away keeps its row.
    @MainActor func testAStarOrBookmarkThatGoesTakesItsRowWithIt() async throws {
        let env = try await AppEnvironment.test()
        let home = env.directories.home
        let a = home.appendingPathComponent("a.txt"), b = home.appendingPathComponent("b.txt")
        let folder = home.appendingPathComponent("Folder", isDirectory: true)
        env.stars.star(a, at: Date()); env.stars.star(b, at: Date())
        XCTAssertTrue(env.bookmarks.add(folder, isDirectory: true, at: Date()))
        let starA = Place.id(.starred, path: a.path), starB = Place.id(.starred, path: b.path)
        let mark = Place.id(.bookmark, path: folder.path), drive = Place.id(.device, path: "/Volumes/Away")
        env.sidebarLayout.update { layout in
            layout.move(starA, before: nil, in: .starred, natural: [starA, starB])
            for id in [starA, mark, drive] { layout.setHidden(id, true) }
        }
        XCTAssertEqual(env.sidebarLayout.layout.starred, [starB, starA])
        env.stars.unstar(a)
        XCTAssertEqual(env.sidebarLayout.layout.starAndBookmarkIDs, [starB, mark])
        XCTAssertEqual(env.sidebarLayout.layout.hidden, [mark, drive])
        env.bookmarks.remove(path: folder.path)
        XCTAssertEqual(env.sidebarLayout.layout.hidden, [drive])
        env.stars.star(a, at: Date())
        XCTAssertTrue(env.bookmarks.add(folder, isDirectory: true, at: Date()))
        let places = PlacesModel(home: home, bookmarks: [folder], starred: [a, b], layout: env.sidebarLayout.layout)
        XCTAssertEqual(places.shown(.starred).map(\.name), ["a.txt", "b.txt"])
        XCTAssertEqual(places.shown(.bookmarks).map(\.name), ["Folder"])
    }

    /// sidebar.json from an earlier Helm can still name stars and bookmarks that went. Launch forgets them, but only
    /// when no document failed to load: with stars.json unreadable, its rows wait for a launch that can read it.
    @MainActor func testRowsAnEarlierHelmKeptForGoneItemsGoAtLaunch() async throws {
        let directories = try directories()
        defer { try? FileManager.default.removeItem(at: directories.applicationSupport) }
        let location = StoreLocation(directory: directories.applicationSupport)
        let kept = directories.home.appendingPathComponent("kept.txt")
        let folder = directories.home.appendingPathComponent("Folder", isDirectory: true)
        let first = try await live(directories)
        first.stars.star(kept, at: Date())
        XCTAssertTrue(first.bookmarks.add(folder, isDirectory: true, at: Date()))
        let current = [Place.id(.starred, path: kept.path), Place.id(.bookmark, path: folder.path)]
        let gone = ["starred-/elsewhere/gone-star.txt", "bookmark-/elsewhere/gone-folder"]
        let others = [Place.id(.device, path: "/Volumes/Away"), "music"]
        first.sidebarLayout.update { $0 = SidebarLayout(hidden: gone + current + others, starred: [gone[0], current[0]]) }
        let saved = await first.flushStores()
        XCTAssertEqual(saved, [])
        let next = try await live(directories)
        XCTAssertEqual(next.sidebarLayout.layout.hidden, (current + others).sorted())
        XCTAssertEqual(next.sidebarLayout.layout.starred, [current[0]])
        let flushed = await next.flushStores()
        XCTAssertEqual(flushed, [])
        XCTAssertFalse(try String(contentsOf: location.sidebar, encoding: .utf8).contains("gone-"))
        // A stars.json this Helm can't read: nothing is forgotten.
        next.sidebarLayout.update { $0.setHidden(gone[0], true) }
        let again = await next.flushStores()
        XCTAssertEqual(again, [])
        try Data(#"{"schemaVersion":2,"items":[]}"#.utf8).write(to: location.stars)
        let unreadable = try await live(directories)
        XCTAssertTrue(unreadable.loadFailures.map(\.document).contains("stars"))
        XCTAssertTrue(unreadable.sidebarLayout.layout.isHidden(gone[0]))
        XCTAssertTrue(unreadable.sidebarLayout.layout.isHidden(current[0]))
    }

    /// A starred folder that's on the disk keeps its row at launch. The cleanup names the row from its path alone, and
    /// the sidebar from a URL that asked the disk, so the two must agree without the cleanup asking.
    @MainActor func testAStarredFolderOnTheDiskKeepsItsHiddenRowAtLaunch() async throws {
        let directories = try directories()
        defer { try? FileManager.default.removeItem(at: directories.applicationSupport) }
        let folder = directories.home.appendingPathComponent("Starred Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let first = try await live(directories)
        first.stars.star(folder, at: Date())
        // The ID the sidebar gives the row, from a URL that asked the disk and so ends in a slash.
        let asked = URL(fileURLWithPath: folder.path)
        XCTAssertTrue(asked.hasDirectoryPath)
        let id = try XCTUnwrap(PlacesModel(home: directories.home, starred: [asked]).starred.first?.id)
        first.sidebarLayout.update { $0.setHidden(id, true) }
        let saved = await first.flushStores()
        XCTAssertEqual(saved, [])
        let next = try await live(directories)
        XCTAssertTrue(next.loadFailures.isEmpty)
        XCTAssertTrue(next.sidebarLayout.layout.isHidden(id))
    }

    @MainActor func testAFailedSaveIsReportedAndRetried() async throws {
        let directories = try directories()
        defer { try? FileManager.default.removeItem(at: directories.applicationSupport) }
        let env = try await live(directories)
        let url = StoreLocation(directory: directories.applicationSupport).sidebar
        env.sidebarLayout.update { $0.setHidden("recent-root", true) }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let failures = await env.flushStores()
        XCTAssertEqual(failures.map(\.document), ["sidebar"])
        XCTAssertEqual(env.sidebarLayout.layout.hidden, ["recent-root"])
        try FileManager.default.removeItem(at: url)
        let retry = await env.flushStores()
        XCTAssertEqual(retry, [])
        let saved = try await SidebarLayoutStore(url: url)
        XCTAssertEqual(saved.layout.hidden, ["recent-root"])
    }
}

@MainActor private final class SidebarTestSettings: KeyValueStoring {
    private var values: [String: Any] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any, forKey key: String) { values[key] = value }
    func register(defaults: [String: Any]) { values.merge(defaults) { old, _ in old } }
}
@MainActor private struct SidebarTestLegacy: LegacyDefaultsReading {
    func data(forKey key: String, domain: String?) -> Data? { nil }
    func storedSetting(for key: SettingKey, domain: String) -> SettingValue? { nil }
    func hasStoredSetting(for key: SettingKey, domain: String) -> Bool { false }
}
