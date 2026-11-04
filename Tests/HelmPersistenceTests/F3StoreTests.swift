// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
@testable import HelmPersistence

final class F3StoreTests: XCTestCase {
    @MainActor func testFailedExistenceProbeDoesNotAuthorizeOverwrite() async throws {
        let directory = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ancestor = directory.appendingPathComponent("blocked")
        try Data("blocker".utf8).write(to: ancestor)
        let url = ancestor.appendingPathComponent("data.json")
        let store = JSONFileStore<[Int]>(url: url, empty: [])
        do { try await store.load(); XCTFail("ENOTDIR is not a missing document") } catch {}
        try FileManager.default.removeItem(at: ancestor)
        try FileManager.default.createDirectory(at: ancestor, withIntermediateDirectories: true)
        let original = Data(#"{"schemaVersion":99,"items":[7]}"#.utf8)
        try original.write(to: url)
        store.replace(with: [2])
        do { try await store.flush(); XCTFail("Failed load must remain read-only") } catch {}
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    @MainActor func testPermissionAndIOErrorsRemainReadOnly() async throws {
        let directory = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("data.json")
        let original = Data(#"{"schemaVersion":99,"items":[7]}"#.utf8)
        try original.write(to: url)
        for code in [13, 5, 20] {
            let store = JSONFileStore<[Int]>(url: url, empty: []) { _ in
                throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoSuchFile.rawValue,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: code)])
            }
            do { try await store.load(); XCTFail("Non-ENOENT read accepted") } catch {}
            store.replace(with: [8])
            do { try await store.flush(); XCTFail("Failed read authorized write") } catch {}
            XCTAssertEqual(try Data(contentsOf: url), original)
        }
    }
    @MainActor func testDirtyReloadPreservesPendingEditAndWritableState() async throws {
        let directory = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("data.json")
        let store = JSONFileStore<[Int]>(url: url, empty: [])
        try await store.load(); store.replace(with: [1]); try await store.flush()
        store.replace(with: [2])
        do { try await store.load(); XCTFail("Dirty reload accepted") } catch {}
        XCTAssertEqual(store.items, [2])
        try await store.flush()
        let other = JSONFileStore<[Int]>(url: url, empty: [])
        try await other.load(); XCTAssertEqual(other.items, [2])
    }
}

private actor F3StoreReadGate {
    let started: XCTestExpectation
    var continuation: CheckedContinuation<Void, Never>?
    var reads: Int = 0
    init(started: XCTestExpectation) { self.started = started }
    func read() async -> Data {
        reads += 1
        if reads == 2 {
            await withCheckedContinuation { continuation = $0; started.fulfill() }
        }
        return Data(#"{"schemaVersion":1,"items":[1]}"#.utf8)
    }
    func finish() { continuation?.resume(); continuation = nil }
}
extension F3StoreTests {
    @MainActor func testConcurrentReloadAndReplaceCannotInvalidateStore() async throws {
        let directory = try temporaryStoreDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let started = expectation(description: "reload suspended")
        let gate = F3StoreReadGate(started: started)
        let store = JSONFileStore<[Int]>(url: directory.appendingPathComponent("data.json"), empty: []) { _ in await gate.read() }
        try await store.load()
        let loading = Task { try await store.load() }
        await fulfillment(of: [started], timeout: 1)
        do { try await store.load(); XCTFail("Concurrent reload accepted") } catch {}
        store.replace(with: [9])
        XCTAssertEqual(store.items, [1])
        await gate.finish(); try await loading.value
        store.replace(with: [2]); try await store.flush()
        XCTAssertEqual(store.items, [2])
    }
}
