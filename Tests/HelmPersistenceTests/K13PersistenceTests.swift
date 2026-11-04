// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmPersistence

final class K13PersistenceTests: XCTestCase {
    /// F-028–F-030: strict mode preserves corrupt bytes and blocks writes.
    @MainActor func testStrictCorruptionCannotOverwrite() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("strict.json")
        let bytes = Data(#"{"schemaVersion":1,"items":[1,"#.utf8)
        try bytes.write(to: url)
        let store = JSONFileStore<[Int]>(url: url, empty: [])
        do { try await store.load(recoverCorruption: false); XCTFail("Accepted truncation") } catch is DecodingError {} catch { XCTFail("\(error)") }
        store.replace(with: [99])
        XCTAssertTrue(store.items.isEmpty)
        do { try await store.flush(); XCTFail("Wrote corrupt file") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 1)
    }

    /// F-028–F-030: empty, truncated, wrong-type and missing envelopes retain exact backups.
    @MainActor func testCorruptionShapesRetainBytes() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let samples = ["", "null", "[]", "{}", #"{"schemaVersion":1,"items":["wrong"]}"#, #"{"schemaVersion":1,"items":null}"#]
        for (index, sample) in samples.enumerated() {
            let url = dir.appendingPathComponent("\(index).json")
            let bytes = Data(sample.utf8)
            try bytes.write(to: url)
            let store = JSONFileStore<[Int]>(url: url, empty: [])
            try await store.load()
            XCTAssertTrue(store.items.isEmpty)
            let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.lastPathComponent.hasPrefix("\(index).json.corrupt-") }
            XCTAssertEqual(backups.count, 1)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), bytes)
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
    }

    /// F-028–F-030: zero/negative/future versions all fail without backups or writes.
    @MainActor func testUnsupportedVersionExtremes() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for version in [Int.min, -1, 0, 2, Int.max] {
            let url = dir.appendingPathComponent("\(version).json")
            let bytes = Data("{\"schemaVersion\":\(version),\"items\":[]}".utf8)
            try bytes.write(to: url)
            let store = JSONFileStore<[Int]>(url: url, empty: [])
            do { try await store.load(); XCTFail("Accepted version \(version)") }
            catch { XCTAssertEqual(error as? PersistenceError, .unsupportedVersion(version)) }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 5)
    }

    /// F-028: replace-before-load must not discard an existing file.
    @MainActor func testMutationBeforeLoadIgnored() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("unloaded.json")
        let store = JSONFileStore<[Int]>(url: url, empty: [])
        store.replace(with: [42])
        XCTAssertTrue(store.items.isEmpty)
        do { try await store.flush(); XCTFail("Unloaded write accepted") }
        catch { XCTAssertEqual(error as? PersistenceError, .modifiedDuringLoad) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    /// F-028: additive unknown envelope keys remain forward compatible within version 1.
    @MainActor func testUnknownEnvelopeKeys() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("unknown.json")
        try Data(#"{"schemaVersion":1,"items":[1,2],"future":{"x":true}}"#.utf8).write(to: url)
        let store = JSONFileStore<[Int]>(url: url, empty: [])
        try await store.load()
        XCTAssertEqual(store.items, [1, 2])
        XCTAssertNil(store.lastError)
    }

    /// F-030, B-030: duplicated canonical paths choose newest access and deterministic ties.
    @MainActor func testRecentDuplicateRecordsOnLoad() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("recent.json")
        let records = [RecentRecord(path: "/z", lastAccessedAt: Date(timeIntervalSince1970: 2)),
                       RecentRecord(path: "/a/../z", lastAccessedAt: Date(timeIntervalSince1970: 1)),
                       RecentRecord(path: "/a", lastAccessedAt: Date(timeIntervalSince1970: 2))]
        try JSONEncoder().encode(VersionedDocument(items: records)).write(to: url)
        let store = try await RecentStore(url: url)
        XCTAssertEqual(store.records.map(\.path), ["/a", "/z"])
        XCTAssertEqual(store.records.last?.lastAccessedAt, Date(timeIntervalSince1970: 2))
        try await store.flush()
    }

    /// F-029, B-027: duplicate canonical additions retain the original timestamp.
    @MainActor func testStarCanonicalDuplicateKeepsDate() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await StarStore(url: dir.appendingPathComponent("stars.json"))
        let date = Date(timeIntervalSince1970: 1)
        store.star(URL(fileURLWithPath: "/offline/é😀"), at: date)
        store.star(URL(fileURLWithPath: "/offline/a/../é😀"), at: date.addingTimeInterval(100))
        XCTAssertEqual(store.records.count, 1)
        XCTAssertEqual(store.records.first?.addedAt, date)
        try await store.flush()
    }

    /// F-028, B-029: same-named offline bookmarks sort with a deterministic path tie break.
    @MainActor func testBookmarkTieOrdering() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try await BookmarkStore(url: dir.appendingPathComponent("bookmarks.json"), home: URL(fileURLWithPath: "/home"))
        XCTAssertTrue(store.add(URL(fileURLWithPath: "/z/same"), isDirectory: true))
        XCTAssertTrue(store.add(URL(fileURLWithPath: "/a/same"), isDirectory: true))
        XCTAssertEqual(store.records.map(\.path), ["/a/same", "/z/same"])
        try await store.flush()
    }

    /// F-068: decoding revalidates active tab indices from hostile session files.
    func testSessionIndexExtremesDecode() throws {
        for index in [Int.min, Int.max] {
            let data = Data("{\"frameAutosaveName\":\"😀\",\"tabs\":[],\"activeTabIndex\":\(index)}".utf8)
            let window = try JSONDecoder().decode(SessionWindow.self, from: data)
            XCTAssertEqual(window.activeTabIndex, 0)
            XCTAssertTrue(window.tabs.isEmpty)
        }
    }

    /// F-028: binary bookmark data and Unicode names survive JSON round trips.
    func testBookmarkOpaqueDataRoundTrip() throws {
        let record = BookmarkRecord(path: "/offline/مرحبا", name: "cafe\u{301}😀", addedAt: .distantPast,
                                    bookmarkData: Data((0...255).map(UInt8.init)))
        let restored = try JSONDecoder().decode(BookmarkRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored, record)
        XCTAssertEqual(Array(restored.name.utf8), Array(record.name.utf8))
    }

    /// F-028–F-030: repeated future schema keys must still block mutation and preserve bytes.
    @MainActor func testDuplicateFutureSchemaKeysRemainReadOnly() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("duplicate-keys.json")
        let bytes = Data(#"{"schemaVersion":99,"schemaVersion":99,"items":[],"items":[]}"#.utf8)
        try bytes.write(to: url)
        let store = JSONFileStore<[Int]>(url: url, empty: [])
        do { try await store.load(); XCTFail("Accepted duplicated future schema") }
        catch { XCTAssertEqual(error as? PersistenceError, .unsupportedVersion(99)) }
        store.replace(with: [42])
        do { try await store.flush(); XCTFail("Overwrote future schema") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 1)
    }

}
