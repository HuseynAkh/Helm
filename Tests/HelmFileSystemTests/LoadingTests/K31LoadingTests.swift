// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmTestKit

final class K31LoadingTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/folder")
    private let generation = Generation(rawValue: 7)
    private func fixture() async throws -> InMemoryFileSystem {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        return fs
    }
    private func collect(_ stream: AsyncStream<TabAction>) async -> [TabAction] {
        var result: [TabAction] = []
        for await action in stream { result.append(action) }
        return result
    }
    private func finished(_ actions: [TabAction], file: StaticString = #filePath, line: UInt = #line) throws -> PresentationSnapshot {
        for action in actions.reversed() {
            if case .loadFinished(let stamp, let snapshot) = action {
                XCTAssertEqual(stamp, generation, file: file, line: line)
                return snapshot
            }
        }
        XCTFail("Missing successful completion", file: file, line: line)
        throw FileSystemError.other("Missing completion")
    }
    func testNaturalOrderHiddenFilteringAndGrouping() async throws {
        let fs = try await fixture()
        for name in ["file10", "file2", ".hidden"] {
            try await fs.createFileExclusively(at: root.appendingPathComponent(name), contents: Data())
        }
        try await fs.createDirectory(at: root.appendingPathComponent("z"))
        let loader = DirectoryLoadPipeline(fileSystem: fs)
        let actions = await collect(loader.load(.directory(root), generation: generation, options: LoadOptions(batchSize: 1)))
        let snapshot = try finished(actions)
        XCTAssertEqual(snapshot.sortedEntries.map(\.name), ["z", "file2", "file10"])
        XCTAssertEqual(snapshot.id, generation)
        let visible = await collect(loader.load(.directory(root), generation: generation, options: LoadOptions(showHidden: true)))
        XCTAssertEqual(try finished(visible).sortedEntries.count, 4)
    }
    func testEmptyDeniedAndUnsupportedAreDistinct() async throws {
        let fs = try await fixture()
        let loader = DirectoryLoadPipeline(fileSystem: fs)
        let empty = await collect(loader.load(.directory(root), generation: generation))
        XCTAssertEqual(try finished(empty).sortedEntries.count, 0)
        await fs.setFailure(.permissionDenied, at: root)
        let denied = await collect(loader.load(.directory(root), generation: generation))
        guard case .loadFailed(let stamp, .permissionDenied)? = denied.last else { return XCTFail("Expected denial") }
        XCTAssertEqual(stamp, generation)
        let unsupported = await collect(loader.load(.recent, generation: generation))
        guard case .loadFailed? = unsupported.last else { return XCTFail("Expected unsupported location failure") }
    }
    func testSupersessionAndExplicitCancellation() async throws {
        let fs = try await fixture()
        await fs.setLatency(nanoseconds: 100_000_000)
        let loader = DirectoryLoadPipeline(fileSystem: fs)
        let old = await loader.load(.directory(root), generation: Generation(rawValue: 6))
        let new = await loader.load(.directory(root), generation: generation)
        let retired = await collect(old)
        XCTAssertTrue(retired.isEmpty)
        let actions = await collect(new)
        _ = try finished(actions)
        let cancelled = await loader.load(.directory(root), generation: generation)
        await loader.cancel()
        let cancelledActions = await collect(cancelled)
        XCTAssertTrue(cancelledActions.isEmpty)
    }
    func testReducerRejectsStaleBufferedResultAndPreservesReloadSelection() async throws {
        let fs = try await fixture()
        let selected = root.appendingPathComponent("selected")
        try await fs.createFileExclusively(at: selected, contents: Data())
        let loader = DirectoryLoadPipeline(fileSystem: fs)
        let stale = await collect(loader.load(.directory(root), generation: generation))
        let context = ReducerContext(now: .distantPast, homeDirectory: root)
        var state = TabState(location: .directory(root), homeDirectory: root)
        state.loadGeneration = Generation(rawValue: 8); state.isLoading = true
        for action in stale { state = TabReducer.reduce(state, action, context: context).0 }
        XCTAssertTrue(state.snapshot.sortedEntries.isEmpty)
        state.isLoading = false
        state.snapshot = try finished(stale)
        state.selection = [ItemID(url: selected)]
        let refresh = await collect(loader.reload(.directory(root), monitorGeneration: state.monitorGeneration))
        XCTAssertEqual(refresh.count, 1)
        for action in refresh { state = TabReducer.reduce(state, action, context: context).0 }
        XCTAssertEqual(state.selection, [ItemID(url: selected)])
    }
    func testHundredThousandEntriesHaveBoundedProgressAndCompleteFinalSnapshot() async throws {
        let fs = try await fixture()
        for index in 0..<100_000 {
            try await fs.createFileExclusively(at: root.appendingPathComponent("item\(index)"), contents: Data())
        }
        let loader = DirectoryLoadPipeline(fileSystem: fs)
        let actions = await collect(loader.load(.directory(root), generation: generation))
        let snapshot = try finished(actions)
        XCTAssertEqual(snapshot.sortedEntries.count, 100_000)
        XCTAssertLessThanOrEqual(actions.count, 10)
        XCTAssertEqual(snapshot.sortedEntries.first?.name, "item0")
        XCTAssertEqual(snapshot.sortedEntries.last?.name, "item99999")
        XCTAssertNotNil(snapshot.index(of: ItemID(url: root.appendingPathComponent("item54321"))))
    }
    func testRecoverableWarningsDoNotAbortAndTerminalErrorsDoNotSucceed() async throws {
        let fs = try await fixture()
        let fixture = K31RecoverableFileSystem(base: fs, root: root)
        let warning = expectation(description: "warning")
        let loader = DirectoryLoadPipeline(fileSystem: fixture)
        let actions = await collect(loader.load(.directory(root), generation: generation, diagnostic: { _ in warning.fulfill() }))
        XCTAssertEqual(try finished(actions).sortedEntries.map(\.name), ["good"])
        await fulfillment(of: [warning], timeout: 2)
        let failing = DirectoryLoadPipeline(fileSystem: K31RecoverableFileSystem(base: fs, root: root, fail: true))
        let failed = await collect(failing.load(.directory(root), generation: generation))
        guard case .loadFailed(_, .timedOut)? = failed.last else { return XCTFail("Terminal read must fail") }
    }
    func testMonitorQuietWindowMaximumAgeAndStickyRoot() async {
        let clock = FakeClock()
        let monitor = DirectoryReloadCoalescer(generation: generation, clock: clock)
        await monitor.receive(.changed(paths: ["a"]))
        clock.advance(by: 0.2)
        await monitor.receive(.changed(paths: ["b"]))
        clock.advance(by: 0.3)
        await monitor.flush()
        var iterator = monitor.actions.makeAsyncIterator()
        guard case .monitorEvent(let stamp, .rescan)? = await iterator.next() else { return XCTFail("Expected one rescan") }
        XCTAssertEqual(stamp, generation)
        for _ in 0..<11 {
            await monitor.receive(.changed(paths: ["c"]))
            clock.advance(by: 0.1)
        }
        await monitor.flush()
        guard case .monitorEvent(_, .rescan)? = await iterator.next() else { return XCTFail("Maximum age refresh") }
        await monitor.receive(.rootChanged)
        await monitor.receive(.rescan)
        await monitor.finish()
        guard case .monitorEvent(_, .rootChanged)? = await iterator.next() else { return XCTFail("Root validation lost") }
        let end = await iterator.next()
        XCTAssertNil(end)
    }
    func testCoalescedMonitorActionDrivesReloadAndRetainsSelection() async throws {
        let fs = try await fixture()
        let selected = root.appendingPathComponent("selected")
        try await fs.createFileExclusively(at: selected, contents: Data())
        let loader = DirectoryLoadPipeline(fileSystem: fs)
        let initial = await collect(loader.load(.directory(root), generation: generation))
        var state = TabState(location: .directory(root), homeDirectory: root)
        state.snapshot = try finished(initial); state.selection = [ItemID(url: selected)]
        let clock = FakeClock()
        let monitor = DirectoryReloadCoalescer(generation: state.monitorGeneration, clock: clock)
        for name in ["newA", "newB"] {
            let url = root.appendingPathComponent(name)
            try await fs.createFileExclusively(at: url, contents: Data())
            await monitor.receive(.changed(paths: [url.path]))
        }
        clock.advance(by: 1)
        await monitor.flush(); await monitor.finish()
        let coalesced = await collect(monitor.actions)
        XCTAssertEqual(coalesced.count, 1)
        let context = ReducerContext(now: clock.now(), homeDirectory: root)
        var reloadCount = 0
        for action in coalesced {
            let reduced = TabReducer.reduce(state, action, context: context)
            state = reduced.0
            for effect in reduced.1 {
                if case .refreshPaths(_, let stamp) = effect {
                    reloadCount += 1
                    let updates = await collect(loader.reload(state.location, monitorGeneration: stamp))
                    for update in updates { state = TabReducer.reduce(state, update, context: context).0 }
                }
            }
        }
        XCTAssertEqual(reloadCount, 1)
        XCTAssertEqual(state.snapshot.sortedEntries.count, 3)
        XCTAssertEqual(state.selection, [ItemID(url: selected)])
    }
    func testEmptyMonitorStreamDoesNotInventAChange() async {
        let monitor = DirectoryReloadCoalescer(generation: generation, clock: FakeClock())
        let events = AsyncStream<MonitorEvent> { $0.finish() }
        await monitor.consume(events)
        let actions = await collect(monitor.actions)
        XCTAssertTrue(actions.isEmpty)
    }
    func testFiniteMonitorStreamFlushesPendingChanges() async {
        let monitor = DirectoryReloadCoalescer(generation: generation, clock: FakeClock())
        let events = AsyncStream<MonitorEvent> { continuation in
            continuation.yield(.changed(paths: ["a"])); continuation.finish()
        }
        await monitor.consume(events)
        let actions = await collect(monitor.actions)
        XCTAssertEqual(actions.count, 1)
        guard case .monitorEvent(_, .rescan)? = actions.first else { return XCTFail("Final rescan missing") }
    }
}
