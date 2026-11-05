// DRAFT: pending review, 2026-11-05
import Foundation
import XCTest
import HelmCore
import HelmPersistence
@testable import HelmApp

final class SevenDocumentFlushTests: XCTestCase {
    @MainActor func testSevenDocumentsFlushDespiteAnySingleFailure() async throws {
        let names = ["bookmarks", "stars", "recent", "session", "trash-origins", "tag-catalog", "view-options"]
        let failingDocuments: [String?] = [nil] + names.map { Optional($0) }
        for failing in failingDocuments {
            let base = try await AppEnvironment.test()
            let log = FlushLog(failing: failing)
            let env = AppEnvironment(settings: base.settings,
                bookmarks: BookmarkSpy(log), stars: StarSpy(log), recents: RecentSpy(log),
                session: SessionSpy(log), trashOrigins: OriginSpy(log),
                tagCatalog: TagSpy(log), viewOptions: OptionsSpy(log),
                fileSystem: base.fileSystem, journal: base.journal, clock: base.clock, directories: base.directories)
            let failures = await env.flushStores()
            XCTAssertEqual(log.attempts, names)
            XCTAssertEqual(failures.map(\.document), failing.map { [$0] } ?? [])
        }
    }
}
@MainActor private final class FlushLog {
    let failing: String?
    var attempts: [String] = []
    init(failing: String?) { self.failing = failing }
    func flush(_ name: String) throws {
        attempts.append(name)
        if name == failing { throw NSError(domain: "AK3b", code: 1) }
    }
}
@MainActor private final class BookmarkSpy: AppBookmarkStoring {
    let log: FlushLog
    init(_ log: FlushLog) { self.log = log }
    var records: [BookmarkRecord] = []
    let changes = Broadcast<[BookmarkRecord]>()
    func add(_ url: URL, isDirectory: Bool, at date: Date) -> Bool { false }
    func remove(path: String) {}
    func flush() async throws { try log.flush("bookmarks") }
}
@MainActor private final class StarSpy: AppStarStoring {
    let log: FlushLog
    init(_ log: FlushLog) { self.log = log }
    var records: [StarRecord] = []
    let changes = Broadcast<[StarRecord]>()
    func isStarred(_ url: URL) -> Bool { false }
    func star(_ url: URL, at date: Date) {}
    func unstar(_ url: URL) {}
    func flush() async throws { try log.flush("stars") }
}
@MainActor private final class RecentSpy: AppRecentStoring {
    let log: FlushLog
    init(_ log: FlushLog) { self.log = log }
    var records: [RecentRecord] = []
    let changes = Broadcast<[RecentRecord]>()
    func recordAccess(to url: URL, kind: FileEntryKind, at date: Date) {}
    func recentRecords() async -> [RecentRecord] { records }
    func clear() {}
    func flush() async throws { try log.flush("recent") }
}
@MainActor private final class SessionSpy: AppSessionStoring {
    let log: FlushLog
    init(_ log: FlushLog) { self.log = log }
    var windows: [SessionWindow] = []
    let changes = Broadcast<[SessionWindow]>()
    func replace(windows: [SessionWindow]) {}
    func flush() async throws { try log.flush("session") }
}
@MainActor private final class OriginSpy: AppTrashOriginStoring {
    let log: FlushLog
    init(_ log: FlushLog) { self.log = log }
    func record(_ items: [TrashedItem]) async {}
    func originalURL(forTrashed url: URL) async -> URL? { nil }
    func flush() async throws { try log.flush("trash-origins") }
}
@MainActor private final class TagSpy: AppTagCatalogStoring {
    let log: FlushLog
    init(_ log: FlushLog) { self.log = log }
    var tags: [FinderTag] = []
    func merge(discovered: [FinderTag]) throws {}
    func rename(_ name: String, to newName: String) throws {}
    func recolor(_ name: String, color: FinderTagColor) throws {}
    func delete(_ name: String) throws {}
    func reorder(names: [String]) throws {}
    func flush() async throws { try log.flush("tag-catalog") }
}
@MainActor private final class OptionsSpy: AppViewOptionsStoring {
    let log: FlushLog
    init(_ log: FlushLog) { self.log = log }
    var defaults = ViewOptions()
    func options(for location: Location) -> ViewOptions { defaults }
    func set(_ options: ViewOptions, for location: Location) throws {}
    func useAsDefaults(_ options: ViewOptions) throws {}
    func useAsDefaults(for location: Location) throws {}
    func removeRecords(forVanishedLocations locations: [Location]) throws {}
    func flush() async throws { try log.flush("view-options") }
}
