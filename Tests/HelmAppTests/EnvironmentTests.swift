// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmPersistence
@testable import HelmApp

final class EnvironmentTests: XCTestCase {
    @MainActor func testMemoryEnvironmentIsolationAndStoreBehaviour() async throws {
        let first = try await AppEnvironment.test()
        let second = try await AppEnvironment.test()
        let home = first.directories.home
        let now = Date(timeIntervalSince1970: 100)
        let exists = await first.fileSystem.exists(home)
        XCTAssertTrue(exists)
        first.settings.set(.bool(true), for: .showHiddenFiles)
        XCTAssertFalse(second.settings.snapshot.showHiddenFiles)
        XCTAssertTrue(first.bookmarks.add(home, isDirectory: true, at: now))
        XCTAssertFalse(first.bookmarks.add(home, isDirectory: true, at: now))
        XCTAssertFalse(first.bookmarks.add(home.appendingPathComponent("file"), isDirectory: false, at: now))
        XCTAssertEqual(first.bookmarks.records.first?.name, "Home")
        first.bookmarks.remove(path: home.path)
        XCTAssertTrue(first.bookmarks.records.isEmpty)
        first.stars.star(home, at: now); first.stars.star(home, at: now)
        XCTAssertEqual(first.stars.records.count, 1)
        XCTAssertTrue(first.stars.isStarred(home)); XCTAssertTrue(second.stars.records.isEmpty)
        first.stars.unstar(home); XCTAssertFalse(first.stars.isStarred(home))
        for index in 0..<310 {
            first.recents.recordAccess(to: home.appendingPathComponent(String(index)), kind: .directory,
                at: Date(timeIntervalSince1970: Double(index)))
        }
        let recent = await first.recents.recentRecords()
        XCTAssertEqual(recent.count, 180); XCTAssertEqual(first.recents.records.count, 300)
        let newest = home.appendingPathComponent("309")
        first.recents.recordAccess(to: newest, kind: .regular, at: .distantPast)
        XCTAssertEqual(first.recents.records.first?.kind, .directory)
        first.recents.clear(); XCTAssertTrue(first.recents.records.isEmpty)
        let windows = [SessionWindow(frameAutosaveName: "test", tabs: [SessionTab(location: .recent)])]
        first.session.replace(windows: windows)
        XCTAssertEqual(first.session.windows, windows); XCTAssertTrue(second.session.windows.isEmpty)
        let trash = URL(fileURLWithPath: "/trash/item")
        await first.trashOrigins.record([TrashedItem(trashedURL: trash, originalURL: home)])
        let origin = await first.trashOrigins.originalURL(forTrashed: trash)
        XCTAssertEqual(origin, home)
        let failures = await first.flushStores()
        XCTAssertTrue(failures.isEmpty)
    }
    @MainActor func testLiveMigrationPrecedesRegistrationAndRoundTrips() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("K22-" + UUID().uuidString)
        let home = root.appendingPathComponent("home")
        let storage = MigrationSettings()
        let env = try await AppEnvironment.live(directories: AppDirectories(home: home, applicationSupport: root),
            settingsStorage: storage, legacyReader: EmptyLegacyReader())
        XCTAssertTrue(storage.migrationWasCompleteAtRegistration)
        XCTAssertTrue(env.bookmarks is BookmarkStore)
        XCTAssertTrue(env.stars is StarStore)
        let saved = [SessionWindow(frameAutosaveName: "saved", tabs: [SessionTab(location: .recent)])]
        env.session.replace(windows: saved)
        env.stars.star(home, at: Date(timeIntervalSince1970: 10))
        let failures = await env.flushStores()
        XCTAssertTrue(failures.isEmpty)
        let reloaded = try await AppEnvironment.live(directories: env.directories,
            settingsStorage: storage, legacyReader: EmptyLegacyReader())
        XCTAssertEqual(reloaded.session.windows, saved)
        XCTAssertEqual(reloaded.stars.records, env.stars.records)
        // Keep this isolated /tmp fixture; the lane instruction forbids deletion.
    }
    @MainActor func testInvalidRootsAndMigrationFailureDoNotRegisterDefaults() async throws {
        let remote = try XCTUnwrap(URL(string: "https://example.invalid/home"))
        do {
            _ = try await AppEnvironment.test(home: remote)
            XCTFail("Non-file root accepted")
        } catch { XCTAssertTrue(error is AppConfigurationError) }
        let storage = MigrationSettings()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("K22-failure-" + UUID().uuidString)
        do {
            _ = try await AppEnvironment.live(directories: AppDirectories(home: root, applicationSupport: root),
                settingsStorage: storage, legacyReader: EmptyLegacyReader(corrupt: true))
            XCTFail("Corrupt migration accepted")
        } catch { XCTAssertFalse(storage.didRegister) }
    }
    @MainActor func testFlushAttemptsRemainingStoresAfterFailure() async throws {
        let base = try await AppEnvironment.test()
        let failing = FailingSession()
        let origins = CountingOrigins()
        let env = AppEnvironment(settings: base.settings, bookmarks: base.bookmarks, stars: base.stars,
            recents: base.recents, session: failing, trashOrigins: origins, fileSystem: base.fileSystem,
            journal: base.journal, clock: base.clock, directories: base.directories)
        let errors = await env.flushStores()
        XCTAssertEqual(errors.map(\.document), ["session"])
        XCTAssertEqual(origins.flushCount, 1)
    }
}

@MainActor private final class FailingSession: AppSessionStoring {
    var windows: [SessionWindow] = []
    let changes = Broadcast<[SessionWindow]>()
    func replace(windows: [SessionWindow]) { self.windows = windows }
    func flush() async throws { throw NSError(domain: "fixture", code: 1) }
}
@MainActor private final class CountingOrigins: AppTrashOriginStoring {
    var flushCount: Int = 0
    func record(_ items: [TrashedItem]) async {}
    func originalURL(forTrashed url: URL) async -> URL? { nil }
    func flush() async throws { flushCount += 1 }
}

@MainActor private final class MigrationSettings: KeyValueStoring {
    var values: [String: Any] = [:]
    var didRegister: Bool = false
    var migrationWasCompleteAtRegistration: Bool = false
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any, forKey key: String) { values[key] = value }
    func register(defaults: [String: Any]) {
        didRegister = true
        migrationWasCompleteAtRegistration = values[LegacyDefaultsMigrator.doneKey] as? Bool == true
        values.merge(defaults) { old, _ in old }
    }
}
@MainActor private struct EmptyLegacyReader: LegacyDefaultsReading {
    var corrupt: Bool = false
    func data(forKey key: String, domain: String?) -> Data? { corrupt ? Data("bad json".utf8) : nil }
    func storedSetting(for key: SettingKey, domain: String) -> SettingValue? { nil }
    func hasStoredSetting(for key: SettingKey, domain: String) -> Bool { false }
}
