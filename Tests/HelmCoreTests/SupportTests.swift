// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmTestKit

final class SupportTests: XCTestCase {
    func testBroadcastSubscribeCancelAndReentrancy() async {
        await MainActor.run {
            let broadcast = Broadcast<Int>()
            var values: [String] = []
            let first = broadcast.subscribe { value in
                values.append("a\(value)")
                if value == 1 { broadcast.send(2) }
            }
            let second = broadcast.subscribe { values.append("b\($0)") }
            broadcast.send(1)
            XCTAssertEqual(values, ["a1", "b1", "a2", "b2"])
            broadcast.cancel(first)
            broadcast.cancel(first)
            broadcast.send(3)
            XCTAssertEqual(values.last, "b3")
            broadcast.cancel(second)
            broadcast.send(4)
            XCTAssertEqual(values.count, 5)
        }
    }

    func testBroadcastChangesDuringDelivery() async {
        await MainActor.run {
            let broadcast = Broadcast<Int>()
            var second: Broadcast<Int>.Token?
            var added: Bool = false
            var received: [Int] = []
            _ = broadcast.subscribe { _ in
                if let token = second { broadcast.cancel(token) }
                if !added {
                    added = true
                    _ = broadcast.subscribe { received.append($0 * 10) }
                }
            }
            second = broadcast.subscribe { received.append($0) }
            broadcast.send(1)
            XCTAssertEqual(received, [])
            broadcast.send(2)
            XCTAssertEqual(received, [20])
        }
    }

    func testClocksAndDiskFixtures() async throws {
        let clock = FakeClock()
        let initial = clock.now()
        XCTAssertEqual(initial, Date(timeIntervalSince1970: 0))
        clock.advance(by: 3)
        let later = clock.now()
        XCTAssertEqual(later.timeIntervalSince(initial), 3)
        let before = Date()
        let live = SystemHelmClock().now()
        XCTAssertGreaterThanOrEqual(live, before)
        let temporary = try TempDirectory()
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporary.url.path))
        let fixture = TreeFixture(root: temporary.url)
        XCTAssertEqual(fixture.file("child").url.deletingLastPathComponent().path, temporary.url.path)
        XCTAssertTrue(fixture.directory("folder").isDirectoryLike)
        try temporary.remove()
        try temporary.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.url.path))
    }

    func testAutoreleaseScopeReturnsAndThrows() throws {
        XCTAssertEqual(AutoreleaseScope.run { 7 }, 7)
        XCTAssertThrowsError(try AutoreleaseScope.run { throw FileNameError.empty })
    }

    func testContractValues() throws {
        let url = URL(fileURLWithPath: "/a")
        let record = RecentRecord(path: url.path, lastAccessedAt: Date(timeIntervalSince1970: 4))
        XCTAssertEqual(try JSONDecoder().decode(RecentRecord.self, from: JSONEncoder().encode(record)), record)
        let legacy = Data(#"{"path":"/old","lastAccessedAt":0}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(RecentRecord.self, from: legacy).kind, .directory)
        XCTAssertThrowsError(try JSONDecoder().decode(RecentRecord.self, from: Data(#"{"path":2}"#.utf8)))
        let trashed = TrashedItem(trashedURL: url, originalURL: URL(fileURLWithPath: "/original"))
        XCTAssertEqual(try JSONDecoder().decode(TrashedItem.self, from: JSONEncoder().encode(trashed)), trashed)
        XCTAssertEqual(LoadOptions(batchSize: -1).batchSize, 1)
        XCTAssertEqual(LoadOptions().batchSize, 512)
        XCTAssertFalse(LoadOptions().showHidden)
        let summary = OperationSummary(id: OperationID(), affectedDirectories: [url], renamedIDs: [:], createdIDs: [ItemID(url: url)], failureCount: 2)
        XCTAssertEqual(summary.failureCount, 2)
        XCTAssertEqual(summary.affectedDirectories, [url])
        let query = SearchQuery(text: "a", scope: .userFolders, bookmarkPaths: ["/b"], homeDirectory: url, lastDirectory: nil, showHidden: true, limit: 50)
        let result = SearchResult(entry: FileEntry(url: url), rank: 10)
        let search = SearchState(query: query, results: [result])
        XCTAssertEqual(search.query, query)
        XCTAssertEqual(search.results, [result])
        XCTAssertTrue(search.isGathering)
        let request = CompletionRequest(parent: url, prefix: "a", isSlashBrowsing: false, showHidden: false, generation: Generation())
        XCTAssertEqual(request.generation, Generation())
        XCTAssertEqual(request.prefix, "a")
        XCTAssertFalse(request.showHidden)
        XCTAssertFalse(AddressEditorState(currentDirectory: url, home: url).isEditing)
        var address = AddressEditorState(currentDirectory: url, home: url)
        address.text = "a"
        address.selectedIndex = 0
        XCTAssertEqual(address.text, "a")
        XCTAssertEqual(address.selectedIndex, 0)
        XCTAssertEqual(Limits.completionCount, 50)
        XCTAssertEqual(Limits.recentCount, 180)
    }
}
