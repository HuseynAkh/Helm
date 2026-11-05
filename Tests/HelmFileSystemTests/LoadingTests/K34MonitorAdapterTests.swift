// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
@testable import HelmFileSystem

final class K34MonitorAdapterTests: XCTestCase {
    func testOldValidationCannotAcknowledgeNewRootEvent() async {
        let coalescer = DirectoryReloadCoalescer(generation: Generation())
        await coalescer.receive(.rootChanged)
        let revision = await coalescer.rootValidationRevision
        await coalescer.receive(.volumeUnmounted)
        let acknowledged = await coalescer.acknowledgeRootValidation(revision: revision)
        XCTAssertFalse(acknowledged)
        let latest = await coalescer.rootValidationRevision
        let accepted = await coalescer.acknowledgeRootValidation(revision: latest)
        XCTAssertTrue(accepted)
        await coalescer.finish()
    }
}

extension K34MonitorAdapterTests {
    @MainActor func testAdapterValidationPublishesSnapshotAndCancellationSuppressesReload() async throws {
        let fs = InMemoryFileSystem(), root = URL(fileURLWithPath: "/watched")
        try await fs.createDirectory(at: root)
        try await fs.createFileExclusively(at: root.appendingPathComponent("child"), contents: Data())
        let runner = DirectoryEffectRunner(loader: DirectoryLoader(fileSystem: fs))
        let tab = TabID(), generation = Generation()
        let watch = runner.run(.tab(tab, .startMonitor(.directory(root), generation))) { _ in }
        let received = expectation(description: "validated snapshot")
        let validation = runner.run(.tab(tab, .validateNavigation(.directory(root), generation))) { action in
            guard case .tab(let id, .monitorSnapshot(let token, let snapshot)) = action else { return }
            XCTAssertEqual(id, tab); XCTAssertEqual(token, generation)
            XCTAssertEqual(snapshot.sortedEntries.map(\.name), ["child"])
            received.fulfill()
        }
        await fulfillment(of: [received], timeout: 2)
        validation?.cancel()
        let liveWatch = try XCTUnwrap(watch)
        liveWatch.cancel()
        XCTAssertNil(runner.run(.tab(tab, .refreshPaths([], generation))) { _ in })
    }

    @MainActor func testFailedValidationTerminatesWithoutRecursiveUnavailableEvent() async {
        let root = URL(fileURLWithPath: "/missing")
        let runner = DirectoryEffectRunner(loader: DirectoryLoader(fileSystem: InMemoryFileSystem()))
        let tab = TabID(), generation = Generation()
        let watch = runner.run(.tab(tab, .startMonitor(.directory(root), generation))) { _ in }
        let received = expectation(description: "terminal validation failure")
        let validation = runner.run(.tab(tab, .validateNavigation(.directory(root), generation))) { action in
            guard case .tab(_, .monitorValidationFailed(let token, _)) = action else {
                XCTFail("Must emit terminal validation failure"); return
            }
            XCTAssertEqual(token, generation); received.fulfill()
        }
        await fulfillment(of: [received], timeout: 2)
        validation?.cancel(); watch?.cancel()
    }
}

extension K34MonitorAdapterTests {
    @MainActor func testReloadCancellationWithLiveWatchAtReadBoundary() async throws {
        let base = InMemoryFileSystem(), root = URL(fileURLWithPath: "/watched")
        try await base.createDirectory(at: root)
        try await base.createFileExclusively(at: root.appendingPathComponent("child"), contents: Data())
        let entered = expectation(description: "reload read entered")
        let ended = expectation(description: "cancelled reload exited")
        let gate = F17ReadGate(entered: entered)
        let fs = F17FileSystemProbe(base: base, counts: F17ReadCounts(), gate: gate)
        let monitor = F17QuietMonitor()
        let runner = DirectoryEffectRunner(loader: DirectoryLoader(fileSystem: fs), monitorFactory: { _ in monitor })
        let tab = TabID(), generation = Generation()
        let watch = try XCTUnwrap(runner.run(.tab(tab, .startMonitor(.directory(root), generation))) { _ in })
        defer { watch.cancel() }
        runner.reloadDidFinish = { ended.fulfill() }
        let callbacks = F17ReadCounts()
        let reload = try XCTUnwrap(runner.run(.tab(tab, .refreshPaths([], generation))) { _ in callbacks.root() })
        await fulfillment(of: [entered], timeout: 2)
        reload.cancel()
        await gate.release()
        await fulfillment(of: [ended], timeout: 2)
        XCTAssertEqual(callbacks.snapshot()[0], 0)
        runner.reloadDidFinish = nil
        let received = expectation(description: "same watch remains usable")
        let next = try XCTUnwrap(runner.run(.tab(tab, .refreshPaths([], generation))) { action in
            guard case .tab(_, .monitorSnapshot(let token, let snapshot)) = action else { XCTFail("Expected snapshot"); return }
            XCTAssertEqual(token, generation)
            XCTAssertEqual(snapshot.sortedEntries.map(\.name), ["child"])
            received.fulfill()
        })
        await fulfillment(of: [received], timeout: 2)
        next.cancel()
    }
}

private actor F17QuietMonitor: DirectoryMonitor {
    nonisolated let events: AsyncStream<MonitorEvent>
    private let output: AsyncStream<MonitorEvent>.Continuation
    init() { let pair = AsyncStream<MonitorEvent>.makeStream(); events = pair.stream; output = pair.continuation }
    func start() async throws {}
    func stop() async { output.finish() }
}
