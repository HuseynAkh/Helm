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
        let unexpected = expectation(description: "cancelled reload cannot publish")
        unexpected.isInverted = true
        let reload = runner.run(.tab(tab, .refreshPaths([], generation))) { _ in unexpected.fulfill() }
        reload?.cancel(); watch?.cancel()
        await fulfillment(of: [unexpected], timeout: 0.05)
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
