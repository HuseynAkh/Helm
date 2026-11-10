// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
@testable import HelmPersistence

// F-029/F-065: documents must retain user metadata through corruption and migration.
final class T2PreferenceTests: XCTestCase {
    private func url() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("T2-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root.appendingPathComponent("preferences.json")
    }
    @MainActor private func catalog(_ raw: String? = nil) async throws -> (TagCatalogStore, URL) {
        let path = try url()
        if let raw { try Data(raw.utf8).write(to: path) }
        return (try await TagCatalogStore(url: path), path)
    }
    @MainActor
    func testDefaultTagOrder() async throws {
        let (s, _) = try await catalog(); XCTAssertEqual(s.tags.map(\.name), ["Red", "Orange", "Yellow", "Green", "Blue", "Purple", "Gray"])
    }
    @MainActor
    func testDefaultColors() async throws {
        let (s, _) = try await catalog(); XCTAssertEqual(s.tags.map(\.rawValue), ["Red\n6", "Orange\n7", "Yellow\n5", "Green\n2", "Blue\n4", "Purple\n3", "Gray\n1"])
    }
    @MainActor
    func testFirstSpellingWins() async throws {
        let (s, _) = try await catalog(); try s.merge(discovered: [FinderTag(name: "RED", colorIndex: 1)]); XCTAssertEqual(s.tags.first?.rawValue, "Red\n6"); XCTAssertEqual(s.tags.count, 7)
    }
    @MainActor
    func testCanonicalNamesDeduplicate() async throws {
        let (s, _) = try await catalog(); try s.merge(discovered: [FinderTag(rawValue: "café"), FinderTag(rawValue: "cafe\u{301}")]); XCTAssertEqual(s.tags.count, 8)
    }
    @MainActor
    func testInvalidDiscoveredNamesFiltered() async throws {
        let (s, _) = try await catalog(); try s.merge(discovered: [FinderTag(rawValue: ""), FinderTag(rawValue: "   "), FinderTag(rawValue: "bad\0name")]); XCTAssertEqual(s.tags.count, 7)
    }
    @MainActor
    func testCaseOnlyRename() async throws {
        let (s, _) = try await catalog(); try s.rename("red", to: "RED"); XCTAssertEqual(s.tags.first?.rawValue, "RED\n6")
    }
    @MainActor
    func testRenamePreservesUnknownSuffix() async throws {
        let (s, _) = try await catalog(); try s.merge(discovered: [FinderTag(rawValue: "custom\n99")]); try s.rename("custom", to: "renamed"); XCTAssertEqual(s.tags.last?.rawValue, "renamed\n99")
    }
    @MainActor
    func testDuplicateRenameAtomic() async throws {
        let (s, _) = try await catalog(); let before = s.tags; XCTAssertThrowsError(try s.rename("Red", to: "BLUE")); XCTAssertEqual(s.tags, before)
    }
    @MainActor
    func testMissingRenameAtomic() async throws {
        let (s, _) = try await catalog(); let before = s.tags; XCTAssertThrowsError(try s.rename("missing", to: "new")); XCTAssertEqual(s.tags, before)
    }
    @MainActor
    func testDeleteCaseInsensitive() async throws {
        let (s, _) = try await catalog(); try s.delete("rED"); XCTAssertEqual(s.tags.count, 6); XCTAssertFalse(s.tags.contains { $0.name == "Red" })
    }
    @MainActor
    func testMissingDeleteAtomic() async throws {
        let (s, _) = try await catalog(); let before = s.tags; XCTAssertThrowsError(try s.delete("missing")); XCTAssertEqual(s.tags, before)
    }
    @MainActor
    func testReorderPermutation() async throws {
        let (s, _) = try await catalog(); let before = s.tags; try s.reorder(names: before.reversed().map { $0.name.uppercased() }); XCTAssertEqual(s.tags, Array(before.reversed()))
    }
    @MainActor
    func testReorderMissingRejected() async throws {
        let (s, _) = try await catalog(); let before = s.tags; XCTAssertThrowsError(try s.reorder(names: Array(before.dropLast()).map(\.name))); XCTAssertEqual(s.tags, before)
    }
    @MainActor
    func testReorderDuplicateRejected() async throws {
        let (s, _) = try await catalog(); let before = s.tags; XCTAssertThrowsError(try s.reorder(names: Array(repeating: "Red", count: 7))); XCTAssertEqual(s.tags, before)
    }
    @MainActor
    func testTagRoundTrip() async throws {
        let (s, p) = try await catalog(); try s.rename("Red", to: "Priority"); try s.delete("Blue"); try await s.flush(); let restored = try await TagCatalogStore(url: p); XCTAssertEqual(restored.tags, s.tags)
    }
    @MainActor
    func testEmptyCatalogPersists() async throws {
        let (s, p) = try await catalog(); for tag in s.tags { try s.delete(tag.name) }; try await s.flush(); let restored = try await TagCatalogStore(url: p); XCTAssertTrue(restored.tags.isEmpty)
    }
    @MainActor
    func testLegacyMigration() async throws {
        let (s, p) = try await catalog(#"{"schemaVersion":0,"items":["Legacy\n4","LEGACY\n6"]}"#); XCTAssertEqual(s.tags.map(\.rawValue), ["Legacy\n4"]); try await s.flush(); let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: p)) as? [String: Any]); XCTAssertEqual(object["schemaVersion"] as? Int, 1)
    }
    @MainActor
    func testCorruptTagBackup() async throws {
        let (s, p) = try await catalog("{broken"); XCTAssertTrue(s.isReadOnly); let backup = try XCTUnwrap(s.recoveryBackupURL); XCTAssertEqual(try Data(contentsOf: backup), Data("{broken".utf8)); XCTAssertEqual(try Data(contentsOf: p), Data("{broken".utf8))
    }
    @MainActor
    func testCorruptTagMutationRefused() async throws {
        let (s, _) = try await catalog("null"); let before = s.tags; XCTAssertThrowsError(try s.delete("Red")); XCTAssertThrowsError(try s.merge(discovered: [])); XCTAssertEqual(s.tags, before)
    }
    @MainActor
    func testCorruptTagFlushRefused() async throws {
        let (s, p) = try await catalog("[]"); do { try await s.flush(); XCTFail("Must refuse") } catch { XCTAssertEqual(error as? PreferenceDocumentError, .recoveryReadOnly) }; XCTAssertEqual(try Data(contentsOf: p), Data("[]".utf8))
    }
    @MainActor
    func testRejectRenameEmpty() async throws {
        let (s, _) = try await catalog(); let before = s.tags; XCTAssertThrowsError(try s.rename("Red", to: "")); XCTAssertEqual(s.tags, before)
    }
    @MainActor
    func testRejectRenameWhitespace() async throws {
        let (s, _) = try await catalog(); let before = s.tags; XCTAssertThrowsError(try s.rename("Red", to: " \t ")); XCTAssertEqual(s.tags, before)
    }
    @MainActor
    func testRejectRenameNewline() async throws {
        let (s, _) = try await catalog(); let before = s.tags; XCTAssertThrowsError(try s.rename("Red", to: "a\nb")); XCTAssertEqual(s.tags, before)
    }
    @MainActor
    func testRejectRenameNul() async throws {
        let (s, _) = try await catalog(); let before = s.tags; XCTAssertThrowsError(try s.rename("Red", to: "a\0b")); XCTAssertEqual(s.tags, before)
    }
    @MainActor
    func testFutureTagVersion() async throws {
        let p = try url(); let bytes = Data(#"{"schemaVersion":99,"items":[]}"#.utf8); try bytes.write(to: p); do { _ = try await TagCatalogStore(url: p); XCTFail("Future schema accepted") } catch { XCTAssertEqual(error as? PersistenceError, .unsupportedVersion(99)) }; XCTAssertEqual(try Data(contentsOf: p), bytes)
    }
    @MainActor
    func testOptionsLRURead() async throws {
        let s = try await LocationViewOptionsStore(url: url(), capacity: 2); try s.set(ViewOptions(viewMode: .list), for: .recent); try s.set(ViewOptions(), for: .trash); _ = s.options(for: .recent); try s.set(ViewOptions(), for: .directory(URL(fileURLWithPath: "/new"))); XCTAssertEqual(s.keysLeastRecentlyUsedFirst, ["symbol:recent", "path:/new"])
    }
    @MainActor
    func testOptionsOverwriteDoesNotGrow() async throws {
        let s = try await LocationViewOptionsStore(url: url()); try s.set(ViewOptions(), for: .recent); try s.set(ViewOptions(viewMode: .list), for: .recent); XCTAssertEqual(s.count, 1); XCTAssertEqual(s.options(for: .recent).viewMode, .list)
    }
    @MainActor
    func testOptionsZeroCapacity() async throws {
        let s = try await LocationViewOptionsStore(url: url(), capacity: 0); try s.set(ViewOptions(viewMode: .list), for: .recent); XCTAssertEqual(s.count, 0); XCTAssertEqual(s.options(for: .recent), s.defaults)
    }
    @MainActor
    func testOptionsNegativeCapacity() async throws {
        let s = try await LocationViewOptionsStore(url: url(), capacity: -1); XCTAssertEqual(s.capacity, 0); try s.set(ViewOptions(), for: .trash); XCTAssertEqual(s.count, 0)
    }
    @MainActor
    func testOptionsDefaultsKeepOverride() async throws {
        let s = try await LocationViewOptionsStore(url: url()); let custom = ViewOptions(iconSize: 200); try s.set(custom, for: .recent); try s.useAsDefaults(ViewOptions(viewMode: .list)); XCTAssertEqual(s.options(for: .recent), custom); XCTAssertEqual(s.options(for: .trash).viewMode, .list)
    }
    @MainActor
    func testOptionsRemoveExactLocations() async throws {
        let s = try await LocationViewOptionsStore(url: url()); try s.set(ViewOptions(), for: .recent); try s.set(ViewOptions(), for: .trash); try s.removeRecords(forVanishedLocations: [.recent, .recent]); XCTAssertEqual(s.keysLeastRecentlyUsedFirst, ["symbol:trash"])
    }
    @MainActor
    func testOptionsRoundTripLRU() async throws {
        let p = try url(); let s = try await LocationViewOptionsStore(url: p); try s.set(ViewOptions(viewMode: .list), for: .recent); try s.set(ViewOptions(iconSize: 200), for: .trash); _ = s.options(for: .recent); try await s.flush(); let restored = try await LocationViewOptionsStore(url: p); XCTAssertEqual(restored.keysLeastRecentlyUsedFirst, ["symbol:trash", "symbol:recent"]); XCTAssertEqual(restored.options(for: .recent).viewMode, .list)
    }
    @MainActor
    func testOptionsCorruptReadOnly() async throws {
        let p = try url(); try Data("{".utf8).write(to: p); let s = try await LocationViewOptionsStore(url: p); XCTAssertTrue(s.isReadOnly); XCTAssertThrowsError(try s.set(ViewOptions(), for: .recent)); XCTAssertThrowsError(try s.useAsDefaults(ViewOptions())); XCTAssertThrowsError(try s.removeRecords(forVanishedLocations: []))
    }
    @MainActor
    func testOptionsCanonicalKey() async throws {
        XCTAssertEqual(LocationViewOptionsStore.stableKey(for: .directory(URL(fileURLWithPath: "/a/../b"))), "path:/b"); XCTAssertNotEqual(LocationViewOptionsStore.stableKey(for: .recent), LocationViewOptionsStore.stableKey(for: .directory(URL(fileURLWithPath: "/recent"))))
    }
    @MainActor
    func testOptionsConcurrentFlushNewestWins() async throws {
        let p = try url()
        let s = try await LocationViewOptionsStore(url: p)
        var lastAdmitted = ViewOptions()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<40 {
                group.addTask { @MainActor in
                    let value = ViewOptions(iconSize: Double(20 + i))
                    try s.set(value, for: .recent)
                    lastAdmitted = value
                    try await s.flush()
                }
            }
            try await group.waitForAll()
        }
        let restored = try await LocationViewOptionsStore(url: p)
        XCTAssertEqual(restored.options(for: .recent), lastAdmitted)
    }
}

private actor F17SaveGate {
    private var release: CheckedContinuation<Void, Never>?
    private var released = false
    let entered: XCTestExpectation
    init(entered: XCTestExpectation) { self.entered = entered }
    func pause(_ revision: UInt64) async {
        guard revision == 1, !released else { return }
        entered.fulfill()
        await withCheckedContinuation { release = $0 }
    }
    func resume() { released = true; release?.resume(); release = nil }
}

extension T2PreferenceTests {
    @MainActor func testCapturedOldFlushCannotOverwriteNewerAdmittedEdit() async throws {
        let p = try url()
        let s = try await LocationViewOptionsStore(url: p)
        let entered = expectation(description: "old snapshot captured")
        let done = expectation(description: "old flush returned")
        let gate = F17SaveGate(entered: entered)
        s.beforeSave = { revision in await gate.pause(revision) }
        try s.set(ViewOptions(iconSize: 40), for: .recent)
        let old = Task { @MainActor in
            defer { done.fulfill() }
            try await s.flush()
        }
        await fulfillment(of: [entered], timeout: 2)
        let lastAdmitted = ViewOptions(iconSize: 140)
        try s.set(lastAdmitted, for: .recent)
        do { try await s.flush() } catch {
            await gate.resume(); throw error
        }
        await gate.resume()
        await fulfillment(of: [done], timeout: 2)
        try await old.value
        // Reopen immediately: no repair flush and no intervening LRU read.
        let restored = try await LocationViewOptionsStore(url: p)
        XCTAssertEqual(restored.options(for: .recent), lastAdmitted)
        s.beforeSave = nil
    }
}
