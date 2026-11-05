// DRAFT: pending review, 2026-11-05
import Foundation
import XCTest
import HelmCore
@testable import HelmFileSystem

private actor OP1ManualMonitor: DirectoryMonitor {
    nonisolated let events: AsyncStream<MonitorEvent>
    nonisolated let output: AsyncStream<MonitorEvent>.Continuation
    init() { let pair = AsyncStream<MonitorEvent>.makeStream(); events = pair.stream; output = pair.continuation }
    func start() async throws {}
    func stop() async { output.finish() }
}

/// FB2-8 and FB2-11: an admitted read always answers, and a directory without a monitor still reconciles.
final class OP1EffectRunnerTests: XCTestCase {
    @MainActor func testValidationStillCompletesWhenANewerRootEventArrivesDuringTheRead() async throws {
        let base = InMemoryFileSystem(), root = URL(fileURLWithPath: "/watched")
        try await base.createDirectory(at: root)
        let entered = expectation(description: "validation read entered")
        let gate = F17ReadGate(entered: entered)
        let fs = F17FileSystemProbe(base: base, counts: F17ReadCounts(), gate: gate)
        let monitor = OP1ManualMonitor()
        let runner = DirectoryEffectRunner(loader: DirectoryLoader(fileSystem: fs), monitorFactory: { _ in monitor })
        let tab = TabID(), generation = Generation()
        let watching = expectation(description: "watch started")
        let rootEvent = expectation(description: "newer root event delivered")
        let watch = try XCTUnwrap(runner.run(.tab(tab, .startMonitor(.directory(root), generation))) { action in
            if case .tab(_, .monitorWatching) = action { watching.fulfill() }
            if case .tab(_, .monitorEvent(_, .rootChanged)) = action { rootEvent.fulfill() }
        })
        defer { watch.cancel() }
        await fulfillment(of: [watching], timeout: 2)
        let answered = expectation(description: "the admitted validation answers")
        let validation = try XCTUnwrap(runner.run(.tab(tab, .validateNavigation(.directory(root), generation))) { action in
            if case .tab(_, .monitorSnapshot) = action { answered.fulfill() }
        })
        await fulfillment(of: [entered], timeout: 2)
        monitor.output.yield(.rootChanged)
        await fulfillment(of: [rootEvent], timeout: 2)
        await gate.release()
        await fulfillment(of: [answered], timeout: 2)
        validation.cancel()
    }
    @MainActor func testDirectoryWithoutAMonitorStillReconcilesOnRequest() async throws {
        let fs = InMemoryFileSystem(), root = URL(fileURLWithPath: "/watched")
        try await fs.createDirectory(at: root)
        try await fs.createFileExclusively(at: root.appendingPathComponent("child"), contents: Data())
        let runner = DirectoryEffectRunner(loader: DirectoryLoader(fileSystem: fs), monitorFactory: { _ in nil })
        let tab = TabID(), generation = Generation()
        let watch = try XCTUnwrap(runner.run(.tab(tab, .startMonitor(.directory(root), generation))) { _ in })
        let received = expectation(description: "reconciled snapshot")
        let refresh = try XCTUnwrap(runner.run(.tab(tab, .refreshPaths([], generation))) { action in
            guard case .tab(_, .monitorSnapshot(_, let snapshot)) = action else { return }
            XCTAssertEqual(snapshot.sortedEntries.map(\.name), ["child"])
            received.fulfill()
        })
        await fulfillment(of: [received], timeout: 2)
        refresh.cancel()
        watch.cancel()
        XCTAssertNil(runner.run(.tab(tab, .refreshPaths([], generation))) { _ in }, "Cancelling retires the passive watch")
    }
    @MainActor func testVirtualLocationStaysUnwatchedAndIsNotPaintedAsFailed() async {
        let runner = DirectoryEffectRunner(loader: DirectoryLoader(fileSystem: InMemoryFileSystem()), monitorFactory: { _ in nil })
        let tab = TabID(), generation = Generation()
        XCTAssertNil(runner.run(.tab(tab, .startMonitor(.trash, generation))) { action in
            XCTFail("A virtual location has no monitor by design; nothing to report: \(action)")
        })
        XCTAssertNil(runner.run(.tab(tab, .refreshPaths([], generation))) { _ in })
    }
}
