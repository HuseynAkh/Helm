// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import Dispatch
import XCTest
import HelmCore
@testable import HelmFileSystem

/// F-035/F-040, B-010: worker preserves producer order, indexes once and honors owned cancellation.
final class T3SnapshotWorkerTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/snapshot")
    private func scale(_ count: Int) async throws {
        let worker = MonitorSnapshotWorker(beforeBuild: { dispatchPrecondition(condition: .notOnQueue(.main)) })
        let entries = (0..<count).reversed().map { FileEntry(url: root.appendingPathComponent("file\($0)"), size: Int64($0)) }
        let snapshot = try await worker.build(location: .directory(root), sortedEntries: entries, sort: .defaultSort)
        XCTAssertEqual(snapshot.sortedEntries, entries)
        XCTAssertEqual(snapshot.rootCount, count)
        XCTAssertEqual(snapshot.indexByID.count, count)
        for (index, entry) in entries.enumerated() {
            XCTAssertEqual(snapshot.index(of: entry.id), index)
            XCTAssertEqual(snapshot.entry(entry.id)?.size, entry.size)
        }
        XCTAssertNil(snapshot.index(of: ItemID(url: root.appendingPathComponent("missing"))))
    }
    func testEmpty() async throws { try await scale(0) }
    func testSingle() async throws { try await scale(1) }
    func testThousand() async throws { try await scale(1000) }
    @MainActor func testHundredThousandFromMainActor() async throws { try await scale(100_000) }
    func testDuplicateIdentityKeepsFirstMetadataAndOrder() async throws {
        let first = FileEntry(url: root.appendingPathComponent("z"), size: 11)
        let last = FileEntry(url: first.url, size: 99)
        let second = FileEntry(url: root.appendingPathComponent("a"), size: 22)
        let snapshot = try await MonitorSnapshotWorker().build(location: .directory(root), sortedEntries: [first, second, last, second], sort: .defaultSort)
        XCTAssertEqual(snapshot.sortedEntries, [first, second])
        XCTAssertEqual(snapshot.rootCount, 2)
        XCTAssertEqual(snapshot.index(of: second.id), 1)
    }
    @MainActor func testQueuedCancellationDoesNotEnterBuildAndFreshWorkerSucceeds() async throws {
        let entered = expectation(description: "first build holds serial worker")
        let release = DispatchSemaphore(value: 0)
        // Only the first call enters this hook until it is released. The cancelled queued
        // request must never enter; a separate worker recovery check follows below.
        let worker = MonitorSnapshotWorker(beforeBuild: {
            entered.fulfill()
            XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
        })
        let location = Location.directory(root)
        let first = Task { try await worker.build(location: location, sortedEntries: [], sort: .defaultSort) }
        await fulfillment(of: [entered], timeout: 2)
        let queuedEntered = expectation(description: "second request reaches occupied worker")
        let queued = Task {
            queuedEntered.fulfill()
            return try await worker.build(location: location, sortedEntries: [], sort: .defaultSort)
        }
        await fulfillment(of: [queuedEntered], timeout: 2)
        queued.cancel()
        first.cancel()
        release.signal()
        for task in [first, queued] {
            do { _ = try await task.value; XCTFail("Cancelled build must discard output") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        let fresh = try await MonitorSnapshotWorker().build(location: location, sortedEntries: [FileEntry(url: root.appendingPathComponent("fresh"))], sort: .defaultSort)
        XCTAssertEqual(fresh.sortedEntries.map(\.name), ["fresh"])
    }
}
