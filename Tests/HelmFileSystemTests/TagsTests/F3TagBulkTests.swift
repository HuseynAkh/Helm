// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import HelmCore
import HelmFileSystem

private actor F3BulkProbe: TagStorage {
    var calls: [ItemID] = []
    func tags(for item: ItemID) -> TagSet { TagSet() }
    func apply(_ edit: TagEdit, to item: ItemID) throws {
        calls.append(item)
        throw CancellationError()
    }
}
final class F3TagBulkTests: XCTestCase {
    func testBulkStopsAfterStorageCancellation() async {
        let storage = F3BulkProbe()
        let urls = [URL(fileURLWithPath: "/a"), URL(fileURLWithPath: "/b")]
        let result = await TagBulkApplier(storage: storage).apply(.add(FinderTag(rawValue: "red")), to: urls)
        let calls = await storage.calls
        XCTAssertEqual(calls, [ItemID(url: urls[0])])
        XCTAssertEqual(result.failures.count, 2)
    }
    func testPrecancelledBulkDoesNotWrite() async {
        let storage = InMemoryTagStorage()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await TagBulkApplier(storage: storage).apply(.add(FinderTag(rawValue: "red")), to: [URL(fileURLWithPath: "/a")])
        }
        let result = await task.value
        XCTAssertTrue(result.succeeded.isEmpty)
    }
}
