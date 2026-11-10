// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import HelmCore

private actor F3TagProbe: TagStorage {
    var calls: [ItemID] = []
    func tags(for item: ItemID) -> TagSet { TagSet() }
    func apply(_ edit: TagEdit, to item: ItemID) throws {
        calls.append(item)
        throw CancellationError()
    }
}
final class F3TagCancellationTests: XCTestCase {
    func testStorageCancellationStopsSubsequentWrites() async {
        let storage = F3TagProbe()
        let items = [ItemID(rawValue: "/a"), ItemID(rawValue: "/b")]
        let result = await TagEditResult.apply(.add(FinderTag(rawValue: "red")), to: items, storage: storage)
        let calls = await storage.calls
        XCTAssertEqual(calls, [items[0]])
        XCTAssertEqual(result.failures.count, 2)
    }
    func testAlreadyCancelledBatchDoesNotWrite() async {
        let storage = InMemoryTagStorage()
        let item = ItemID(rawValue: "/a")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await TagEditResult.apply(.add(FinderTag(rawValue: "red")), to: [item], storage: storage)
        }
        let result = await task.value
        XCTAssertTrue(result.succeeded.isEmpty)
        let tags = try? await storage.tags(for: item)
        XCTAssertEqual(tags, TagSet())
    }
}

private actor F3SuspendedTags: TagStorage {
    let started: XCTestExpectation
    var continuation: CheckedContinuation<Void, Never>?
    var calls: [ItemID] = []
    init(started: XCTestExpectation) { self.started = started }
    func tags(for item: ItemID) -> TagSet { TagSet() }
    func apply(_ edit: TagEdit, to item: ItemID) async {
        calls.append(item)
        await withCheckedContinuation { continuation = $0; started.fulfill() }
    }
    func finish() { continuation?.resume(); continuation = nil }
}
extension F3TagCancellationTests {
    func testCancellationDuringWritePreservesCompletedOutcome() async {
        let started = expectation(description: "first write started")
        let storage = F3SuspendedTags(started: started)
        let items = [ItemID(rawValue: "/a"), ItemID(rawValue: "/b")]
        let task = Task { await TagEditResult.apply(.add(FinderTag(rawValue: "red")), to: items, storage: storage) }
        await fulfillment(of: [started], timeout: 1)
        task.cancel()
        await storage.finish()
        let result = await task.value
        let calls = await storage.calls
        XCTAssertEqual(calls, [items[0]])
        XCTAssertEqual(result.succeeded, [items[0]])
        XCTAssertEqual(result.failures.map(\.item), [items[1]])
    }
}
