// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
@testable import HelmFileSystem

private actor F14Monitor: DirectoryMonitor {
    nonisolated let events: AsyncStream<MonitorEvent>
    nonisolated let output: AsyncStream<MonitorEvent>.Continuation
    let fails: Bool
    private(set) var stops = 0
    init(fails: Bool) {
        self.fails = fails
        let pair = AsyncStream<MonitorEvent>.makeStream()
        events = pair.stream; output = pair.continuation
    }
    func start() async throws { if fails { throw FileSystemError.permissionDenied } }
    func stop() async { stops += 1; output.finish() }
}

final class F14MonitorRecoveryTests: XCTestCase {
    @MainActor func testStartupFailureRetriesFreshWatchAndReconciles() async throws {
        let root = URL(fileURLWithPath: "/watched")
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        let first = F14Monitor(fails: true), second = F14Monitor(fails: false)
        var attempts = 0
        let runner = DirectoryEffectRunner(loader: DirectoryLoader(fileSystem: fs), monitorFactory: { _ in
            attempts += 1
            return attempts == 1 ? first : second
        }, retryDelay: { _ in await Task.yield() })
        let tab = TabID(), generation = Generation()
        let recovered = expectation(description: "reconcile recovery")
        let change = expectation(description: "subsequent changes")
        let handle = runner.run(.tab(tab, .startMonitor(.directory(root), generation))) { action in
            if case .tab(_, .monitorEvent(_, .rootChanged)) = action { recovered.fulfill() }
            if case .tab(_, .monitorEvent(_, .rescan)) = action { change.fulfill() }
        }
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertEqual(attempts, 2)
        let stops = await first.stops
        XCTAssertEqual(stops, 1)
        second.output.yield(.rescan)
        await fulfillment(of: [change], timeout: 2)
        handle?.cancel()
    }

    @MainActor func testRepeatedFailuresAreBoundedAndRetireWatch() async {
        var attempts = 0
        let runner = DirectoryEffectRunner(loader: DirectoryLoader(fileSystem: InMemoryFileSystem()), monitorFactory: { _ in
            attempts += 1
            return F14Monitor(fails: true)
        }, retryDelay: { _ in await Task.yield() })
        let tab = TabID(), generation = Generation()
        let exhausted = expectation(description: "bounded degraded state")
        let handle = runner.run(.tab(tab, .startMonitor(.directory(URL(fileURLWithPath: "/missing")), generation))) { action in
            if case .tab(_, .monitorStopped(_, _, let retrying)) = action, !retrying { exhausted.fulfill() }
        }
        await fulfillment(of: [exhausted], timeout: 2)
        XCTAssertEqual(attempts, 3)
        XCTAssertNil(runner.run(.tab(tab, .refreshPaths([], generation))) { _ in XCTFail("Stopped watch must be retired") })
        handle?.cancel()
    }
}

extension F14MonitorRecoveryTests {
    @MainActor func testRecoveryThroughStorePublishesAndRebindsThenReceivesChange() async throws {
        let root = URL(fileURLWithPath: "/watched")
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        try await fs.createFileExclusively(at: root.appendingPathComponent("first"), contents: Data())
        var monitors: [F14Monitor] = []
        let rebound = expectation(description: "root validation rebinds watch")
        let runner = DirectoryEffectRunner(loader: DirectoryLoader(fileSystem: fs), monitorFactory: { _ in
            let monitor = F14Monitor(fails: monitors.isEmpty)
            monitors.append(monitor)
            if monitors.count == 3 { rebound.fulfill() }
            return monitor
        }, retryDelay: { _ in await Task.yield() })
        let tab = TabState(location: .directory(root), homeDirectory: root)
        let store = WindowStore(window: WindowState(tabs: [tab.id], activeTabID: tab.id), tabs: [tab], runner: runner,
                                context: ReducerContext(now: .distantPast, homeDirectory: root))
        let changed = expectation(description: "post-recovery snapshot")
        _ = store.snapshots.subscribe { value in
            if value.tabs[tab.id]?.snapshot.sortedEntries.map(\.name) == ["first", "second"] { changed.fulfill() }
        }
        store.send(.tab(tab.id, .deactivated))
        store.send(.tab(tab.id, .activated))
        await fulfillment(of: [rebound], timeout: 3)
        XCTAssertEqual(store.state.tabs[tab.id]?.snapshot.sortedEntries.map(\.name), ["first"])
        XCTAssertFalse(store.state.tabs[tab.id]?.monitorDegraded ?? true)
        XCTAssertEqual(monitors.count, 3)
        try await fs.createFileExclusively(at: root.appendingPathComponent("second"), contents: Data())
        monitors.last?.output.yield(.rescan)
        await fulfillment(of: [changed], timeout: 3)
        store.send(.shutdown)
    }

    @MainActor func testFiniteSourceIsRetiredAndRetried() async {
        var attempts = 0
        let recovered = expectation(description: "finite source replaced")
        let runner = DirectoryEffectRunner(loader: DirectoryLoader(fileSystem: InMemoryFileSystem()), monitorFactory: { _ in
            attempts += 1
            let monitor = F14Monitor(fails: false)
            if attempts == 1 { monitor.output.finish() }
            return monitor
        }, retryDelay: { _ in await Task.yield() })
        let handle = runner.run(.tab(TabID(), .startMonitor(.directory(URL(fileURLWithPath: "/root")), Generation()))) { action in
            if case .tab(_, .monitorEvent(_, .rootChanged)) = action { recovered.fulfill() }
        }
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertEqual(attempts, 2)
        handle?.cancel()
    }
}
