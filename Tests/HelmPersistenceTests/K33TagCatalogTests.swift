// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import HelmCore
@testable import HelmPersistence

final class K33TagCatalogTests: XCTestCase {
    @MainActor func testDefaultsEditsAndRoundTrip() async throws {
        let directory = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tags.json")
        let store = try await TagCatalogStore(url: url)
        XCTAssertEqual(store.tags.count, 7)
        XCTAssertEqual(Set(store.tags.compactMap(\.colorIndex)), Set(1...7))
        try store.rename("RED", to: "Urgent")
        try store.recolor("urgent", color: .purple)
        try store.delete("orange")
        let order = store.tags.map(\.name).reversed().map { $0 }
        try store.reorder(names: order)
        try await store.flush()
        let restored = try await TagCatalogStore(url: url)
        XCTAssertEqual(restored.tags, store.tags)
        XCTAssertEqual(restored.tags.last?.color, .purple)
    }
    @MainActor func testValidationAndUnicodeMerge() async throws {
        let directory = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await TagCatalogStore(url: directory.appendingPathComponent("tags.json"))
        let original = store.tags
        XCTAssertThrowsError(try store.rename("Red", to: "blue"))
        for name in ["", " \t", "a\nb", "a\0b"] { XCTAssertThrowsError(try store.rename("Red", to: name)) }
        XCTAssertThrowsError(try store.rename("missing", to: "New"))
        XCTAssertThrowsError(try store.recolor("missing", color: .red))
        XCTAssertThrowsError(try store.delete("missing"))
        XCTAssertThrowsError(try store.reorder(names: ["Red", "Red"]))
        XCTAssertEqual(store.tags, original)
        try store.merge(discovered: [FinderTag(rawValue: "Café\n99"), FinderTag(rawValue: "CAFE\u{301}\n2"),
                                     FinderTag(rawValue: "red\n1"), FinderTag(rawValue: "\n2")])
        XCTAssertEqual(store.tags.count, 8)
        try store.rename("café", to: "Coffee")
        XCTAssertEqual(store.tags.last?.rawValue, "Coffee\n99")
        try store.merge(discovered: [FinderTag(rawValue: "Plain"), FinderTag(rawValue: "Odd\nfuture")])
        try store.rename("Plain", to: "Simple")
        try store.rename("Odd", to: "Unusual")
        XCTAssertEqual(store.tags.suffix(2).map(\.rawValue), ["Simple", "Unusual\nfuture"])
    }
    @MainActor func testVersionZeroMigrationAndEmptyCatalogue() async throws {
        let directory = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tags.json")
        try JSONEncoder().encode(VersionedDocument(schemaVersion: 0, items: ["Work\n4", "WORK\n6", "Unknown\n88"])).write(to: url)
        let store = try await TagCatalogStore(url: url)
        XCTAssertEqual(store.tags.map(\.rawValue), ["Work\n4", "Unknown\n88"])
        try await store.flush()
        let document = try JSONDecoder().decode(VersionedDocument<[FinderTag]>.self, from: Data(contentsOf: url))
        XCTAssertEqual(document.schemaVersion, 1)
        try store.delete("work"); try store.delete("unknown"); try await store.flush()
        let restored = try await TagCatalogStore(url: url)
        XCTAssertTrue(restored.tags.isEmpty)
    }
    @MainActor func testFutureVersionRefusedWithoutModification() async throws {
        let directory = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tags.json")
        let bytes = Data(#"{"schemaVersion":99,"items":[]}"#.utf8)
        try bytes.write(to: url)
        do { _ = try await TagCatalogStore(url: url); XCTFail("Future version accepted") }
        catch { XCTAssertEqual(error as? PersistenceError, .unsupportedVersion(99)) }
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    @MainActor func testCorruptionRetainsOriginalAndBackup() async throws {
        let directory = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tags.json")
        let bytes = Data("broken".utf8); try bytes.write(to: url)
        let store = try await TagCatalogStore(url: url)
        XCTAssertEqual(store.tags, TagCatalogStore.defaultTags)
        XCTAssertTrue(store.isReadOnly)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.recoveryBackupURL)), bytes)
        XCTAssertThrowsError(try store.merge(discovered: []))
        do { try await store.flush(); XCTFail("Recovery wrote original") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    @MainActor func testConcurrentMergesAndFlushes() async throws {
        let directory = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("tags.json")
        let store = try await TagCatalogStore(url: url)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<80 {
                group.addTask {
                    try await store.merge(discovered: [FinderTag(name: "Tag \(index)", colorIndex: index % 8)])
                    try await store.flush()
                }
            }
            try await group.waitForAll()
        }
        try await store.flush()
        let restored = try await TagCatalogStore(url: url)
        XCTAssertEqual(restored.tags.count, 87)
        XCTAssertEqual(restored.tags, store.tags)
    }
}
