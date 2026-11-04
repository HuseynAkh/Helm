// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
@testable import HelmPersistence

final class K33PreferenceDocumentTests: XCTestCase {
    func testUnloadedAndFailedReadNeverAuthorizeSave() async throws {
        let directory = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("data.json")
        let original = Data("original".utf8); try original.write(to: url)
        let file = PreferenceDocumentFile<[Int]>(url: url)
        do { try await file.save([1], revision: 1); XCTFail("Unloaded write") } catch {}
        do {
            _ = try await file.load(defaults: []) { _ in throw PersistenceError.unsupportedVersion(99) }
            XCTFail("Failed load accepted")
        } catch {}
        do { try await file.save([1], revision: 1); XCTFail("Failed read write") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testStaleRevisionCannotReplaceNewerSnapshot() async throws {
        let directory = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("data.json")
        let file = PreferenceDocumentFile<[Int]>(url: url)
        _ = try await file.load(defaults: []) { try JSONDecoder().decode(VersionedDocument<[Int]>.self, from: $0).items }
        try await file.save([2], revision: 2)
        try await file.save([1], revision: 1)
        XCTAssertEqual(try JSONDecoder().decode(VersionedDocument<[Int]>.self, from: Data(contentsOf: url)).items, [2])
    }
    @MainActor func testFlushFailureCanRetryWithoutLosingEdits() async throws {
        let directory = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let parent = directory.appendingPathComponent("new")
        let url = parent.appendingPathComponent("tags.json")
        let store = try await TagCatalogStore(url: url)
        try store.rename("Red", to: "Priority")
        try Data("blocker".utf8).write(to: parent)
        do { try await store.flush(); XCTFail("Blocked write succeeded") } catch {}
        XCTAssertEqual(store.tags.first?.name, "Priority")
        try FileManager.default.removeItem(at: parent)
        try await store.flush()
        let restored = try await TagCatalogStore(url: url)
        XCTAssertEqual(restored.tags, store.tags)
    }
}
