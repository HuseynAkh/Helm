// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import Dispatch
import XCTest
import HelmCore
@testable import HelmFileSystem

final class F10SnapshotWorkerTests: XCTestCase {
    @MainActor func testConstructionRunsOffMainQueueAndKeepsSortedInputAndIndex() async throws {
        let worker = MonitorSnapshotWorker(beforeBuild: {
            dispatchPrecondition(condition: .notOnQueue(.main))
        })
        let root = URL(fileURLWithPath: "/a")
        let entries = ["z", "a"].map { FileEntry(url: root.appendingPathComponent($0)) }
        let snapshot = try await worker.build(location: .directory(root), sortedEntries: entries, sort: .defaultSort)
        // Deliberately non-natural input detects a second sorting pass.
        XCTAssertEqual(snapshot.sortedEntries.map(\.name), ["z", "a"])
        XCTAssertEqual(snapshot.index(of: entries[1].id), 1)
        XCTAssertEqual(snapshot.rootCount, 2)
    }
    func testCancelledWorkerDoesNotConstructSnapshot() async {
        let worker = MonitorSnapshotWorker(beforeBuild: { XCTFail("Cancelled work must not start building") })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await worker.build(location: .directory(URL(fileURLWithPath: "/a")), sortedEntries: [], sort: .defaultSort)
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    @MainActor func testCancellationDuringConstructionDiscardsResult() async {
        let entered = expectation(description: "worker entered construction")
        let release = DispatchSemaphore(value: 0)
        let worker = MonitorSnapshotWorker(beforeBuild: {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
        })
        let task = Task {
            try await worker.build(location: .directory(URL(fileURLWithPath: "/a")), sortedEntries: [], sort: .defaultSort)
        }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        release.signal()
        do { _ = try await task.value; XCTFail("A retired build must not publish its result") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

}

extension F10SnapshotWorkerTests {
    @MainActor func testInactiveStoreReconcilesWithoutPostActivationMonitorEvent() async throws {
        let root = URL(fileURLWithPath: "/a")
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        let old = FileEntry(url: root.appendingPathComponent("old"))
        let new = FileEntry(url: root.appendingPathComponent("new"))
        try await fs.createFileExclusively(at: old.url, contents: Data())
        var tab = TabState(location: .directory(root), homeDirectory: root)
        tab.snapshot = SnapshotBuilder.build(location: tab.location, entries: [old])
        let runner = DirectoryEffectRunner(loader: DirectoryLoader(fileSystem: fs))
        let store = WindowStore(window: WindowState(tabs: [tab.id], activeTabID: tab.id), tabs: [tab],
                                runner: runner, context: ReducerContext(now: .distantPast, homeDirectory: root))
        defer { store.send(.shutdown) }
        store.send(.tab(tab.id, .deactivated))
        try await fs.removeItem(at: old.url)
        try await fs.createFileExclusively(at: new.url, contents: Data())
        let received = expectation(description: "activation reconciled the unwatched interval")
        let token = store.snapshots.subscribe { value in
            if value.tabs[tab.id]?.snapshot.sortedIDs == [new.id] { received.fulfill() }
        }
        store.send(.tab(tab.id, .activated))
        await fulfillment(of: [received], timeout: 2)
        store.snapshots.cancel(token)
        XCTAssertEqual(store.state.tabs[tab.id]?.snapshot.sortedIDs, [new.id])
    }
}
