// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import HelmCore
import HelmPersistence

final class JSONFileStoreTests: XCTestCase {
    @MainActor func testRoundTripAndConcurrentSaves() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("data.json")
        let store = JSONFileStore<[Int]>(url: url, empty: [])
        try await store.load()
        var emissions: [[Int]] = []
        let token = store.changes.subscribe { emissions.append($0) }
        store.replace(with: [1])
        let first = Task { try await store.flush() }
        store.replace(with: [2])
        let second = Task { try await store.flush() }
        try await first.value; try await second.value
        let reloaded = JSONFileStore<[Int]>(url: url, empty: [])
        try await reloaded.load()
        XCTAssertEqual(reloaded.items, [2])
        XCTAssertEqual(emissions, [[1], [2]])
        store.changes.cancel(token)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 1)
        XCTAssertNotNil(json["items"])
    }
    @MainActor func testCorruptionBacksUpExactBytesThenStartsEmpty() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("data.json")
        let bytes = Data("{broken".utf8)
        try bytes.write(to: url)
        let store = JSONFileStore<[Int]>(url: url, empty: [])
        try await store.load()
        XCTAssertTrue(store.items.isEmpty)
        let backups = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains(".corrupt-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), bytes)
        store.replace(with: [3]); try await store.flush()
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), bytes)
    }
    @MainActor func testFutureSchemaIsUntouchedAndCannotBeSaved() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("future.json")
        let bytes = Data(#"{"schemaVersion":99,"items":{"unknown":true}}"#.utf8)
        try bytes.write(to: url)
        let store = JSONFileStore<[Int]>(url: url, empty: [])
        do { try await store.load(); XCTFail("future schema accepted") }
        catch { XCTAssertEqual(error as? PersistenceError, .unsupportedVersion(99)) }
        store.replace(with: [4])
        do { try await store.flush(); XCTFail("future schema overwritten") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 1)
    }
    @MainActor func testDebounceAndWriteFailure() async throws {
        let dir = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("data.json")
        let store = JSONFileStore<[Int]>(url: url, empty: [])
        try await store.load()
        store.replace(with: [1]); store.replace(with: [2])
        try await Task.sleep(nanoseconds: 700_000_000)
        let document = try JSONDecoder().decode(VersionedDocument<[Int]>.self, from: Data(contentsOf: url))
        XCTAssertEqual(document.items, [2])
        let blocked = dir.appendingPathComponent("blocked")
        let failing = JSONFileStore<[Int]>(url: blocked.appendingPathComponent("data.json"), empty: [])
        try await failing.load()
        try Data().write(to: blocked)
        failing.replace(with: [1])
        do { try await failing.flush(); XCTFail("expected IO failure") } catch {}
        XCTAssertNotNil(failing.lastError)
    }
}
