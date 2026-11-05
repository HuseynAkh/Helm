// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import HelmCore
@testable import HelmPersistence

final class K33LocationViewOptionsTests: XCTestCase {
    @MainActor func testRoundTripDefaultsInheritanceAndStableKeys() async throws {
        let directory = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("views.json")
        let store = try await LocationViewOptionsStore(url: url)
        let options = ViewOptions(viewMode: .list, groupBy: .tag, iconSize: 120, showColumns: [.tags], textSize: 18)
        let location = Location.directory(URL(fileURLWithPath: "/missing/a/../b"))
        try store.set(options, for: location)
        XCTAssertEqual(store.options(for: .directory(URL(fileURLWithPath: "/missing/b"))), options)
        XCTAssertEqual(store.count, 1)
        try store.useAsDefaults(for: location)
        XCTAssertEqual(store.options(for: .recent), options)
        try store.set(ViewOptions(), for: .trash)
        try store.useAsDefaults(ViewOptions(iconSize: 200))
        XCTAssertEqual(store.options(for: .trash), ViewOptions())
        XCTAssertEqual(store.options(for: location), options)
        XCTAssertEqual(store.options(for: .recent).iconSize, 200)
        try await store.flush()
        let restored = try await LocationViewOptionsStore(url: url)
        XCTAssertEqual(restored.defaults, store.defaults)
        XCTAssertEqual(restored.keysLeastRecentlyUsedFirst, store.keysLeastRecentlyUsedFirst)
        XCTAssertEqual(restored.options(for: location), options)
        XCTAssertNotEqual(LocationViewOptionsStore.stableKey(for: .recent), LocationViewOptionsStore.stableKey(for: .directory(URL(fileURLWithPath: "/recent"))))
    }
    @MainActor func testLRUEvictionReadTouchAndExplicitRemoval() async throws {
        let directory = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("views.json")
        let store = try await LocationViewOptionsStore(url: url, capacity: 2)
        let custom = ViewOptions(iconSize: 180)
        try store.set(custom, for: .recent); try store.set(custom, for: .trash)
        _ = store.options(for: .recent)
        let vanished = Location.directory(URL(fileURLWithPath: "/vanished"))
        try store.set(custom, for: vanished)
        XCTAssertEqual(store.options(for: .trash), ViewOptions())
        XCTAssertEqual(store.options(for: vanished), custom)
        XCTAssertEqual(store.count, 2)
        try await store.flush()
        let restored = try await LocationViewOptionsStore(url: url, capacity: 1)
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.options(for: vanished), custom)
        try restored.removeRecords(forVanishedLocations: [.trash])
        XCTAssertEqual(restored.count, 1)
        try restored.removeRecords(forVanishedLocations: [vanished])
        XCTAssertEqual(restored.count, 0)
    }
    @MainActor func testZeroAndNegativeCapacity() async throws {
        let directory = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for capacity in [0, -1] {
            let store = try await LocationViewOptionsStore(url: directory.appendingPathComponent("\(capacity).json"), capacity: capacity)
            try store.set(ViewOptions(iconSize: 200), for: .recent)
            XCTAssertEqual(store.count, 0)
            XCTAssertEqual(store.options(for: .recent), ViewOptions())
            try await store.flush()
        }
    }
    @MainActor func testCorruptAndNestedFutureDocumentsStayReadOnly() async throws {
        let directory = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for (index, text) in ["broken", #"{"schemaVersion":1,"items":{"defaults":{"version":99},"records":[]}}"#].enumerated() {
            let url = directory.appendingPathComponent("\(index).json")
            let bytes = Data(text.utf8); try bytes.write(to: url)
            let store = try await LocationViewOptionsStore(url: url)
            XCTAssertTrue(store.isReadOnly)
            XCTAssertEqual(store.defaults, ViewOptions())
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.recoveryBackupURL)), bytes)
            XCTAssertThrowsError(try store.set(ViewOptions(), for: .recent))
            XCTAssertThrowsError(try store.useAsDefaults(ViewOptions()))
            XCTAssertThrowsError(try store.useAsDefaults(for: .recent))
            XCTAssertThrowsError(try store.removeRecords(forVanishedLocations: [.recent]))
            do { try await store.flush(); XCTFail("Recovery authorized a write") } catch {}
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }
    @MainActor func testFutureEnvelopeAndReadFailure() async throws {
        let directory = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("future.json")
        let bytes = Data(#"{"schemaVersion":100,"items":{}}"#.utf8); try bytes.write(to: url)
        do { _ = try await LocationViewOptionsStore(url: url); XCTFail("Future accepted") }
        catch { XCTAssertEqual(error as? PersistenceError, .unsupportedVersion(100)) }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        for tagStore in [false, true] {
            do {
                if tagStore { _ = try await TagCatalogStore(url: url.appendingPathComponent("blocked")) }
                else { _ = try await LocationViewOptionsStore(url: url.appendingPathComponent("blocked")) }
                XCTFail("ENOTDIR accepted")
            } catch {}
        }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    @MainActor func testDuplicateRecordsLastWins() async throws {
        let directory = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("views.json")
        let document = LocationOptionsDocument(defaults: ViewOptions(), records: [
            LocationOptionsRecord(key: "symbol:recent", options: ViewOptions(iconSize: 20)),
            LocationOptionsRecord(key: "symbol:trash", options: ViewOptions()),
            LocationOptionsRecord(key: "symbol:recent", options: ViewOptions(iconSize: 200))])
        try JSONEncoder().encode(VersionedDocument(items: document)).write(to: url)
        let store = try await LocationViewOptionsStore(url: url)
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store.keysLeastRecentlyUsedFirst, ["symbol:trash", "symbol:recent"])
        XCTAssertEqual(store.options(for: .recent).iconSize, 200)
    }
    @MainActor func testConcurrentUpdatesAndFlushes() async throws {
        let directory = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("views.json")
        let store = try await LocationViewOptionsStore(url: url, capacity: 100)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<80 {
                group.addTask {
                    try await store.set(ViewOptions(iconSize: Double(30 + index)), for: .directory(URL(fileURLWithPath: "/folder/\(index)")))
                    try await store.flush()
                }
            }
            try await group.waitForAll()
        }
        try await store.flush()
        let restored = try await LocationViewOptionsStore(url: url)
        XCTAssertEqual(restored.count, 80)
        for index in 0..<80 {
            XCTAssertEqual(restored.options(for: .directory(URL(fileURLWithPath: "/folder/\(index)"))).iconSize, Double(30 + index))
        }
    }
}
