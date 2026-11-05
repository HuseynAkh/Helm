// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class K34MonitorLifecycleTests: XCTestCase {
    @MainActor func testValidationHandlesCancelledByRefreshAndShutdown() async {
        let root = URL(fileURLWithPath: "/root"), tab = TabState(location: .directory(URL(fileURLWithPath: "/root")), homeDirectory: URL(fileURLWithPath: "/root"))
        let runner = K34ValidationRunner()
        let store = WindowStore(window: WindowState(tabs: [tab.id], activeTabID: tab.id), tabs: [tab],
                                runner: runner, context: ReducerContext(now: Date(), homeDirectory: root))
        store.send(.tab(tab.id, .monitorEvent(tab.monitorGeneration, .rootChanged)))
        store.send(.tab(tab.id, .refresh))
        XCTAssertEqual(runner.cancelled, 1)
        let generation = store.state.tabs[tab.id]?.monitorGeneration ?? Generation()
        store.send(.tab(tab.id, .monitorEvent(generation, .rootChanged)))
        // FB2-8: a foreground refresh defers validation until its load finishes.
        XCTAssertEqual(runner.started, 1)
        XCTAssertEqual(store.state.tabs[tab.id]?.monitorNeedsValidation, true)
        let loading = store.state.tabs[tab.id]
        store.send(.tab(tab.id, .loadFinished(loading?.loadGeneration ?? Generation(),
                                             PresentationSnapshot(location: tab.location))))
        XCTAssertEqual(runner.started, 2, "Deferred validation must start after refresh completes")
        XCTAssertEqual(store.state.tabs[tab.id]?.monitorValidationPending, true)
        store.send(.shutdown)
        XCTAssertEqual(runner.cancelled, 2)
    }
    func testValidationFailureRejectsStaleGenerationAndDoesNotRequestMoreValidation() {
        let root = URL(fileURLWithPath: "/root")
        let tab = TabState(location: .directory(root), homeDirectory: root)
        let context = ReducerContext(now: Date(), homeDirectory: root)
        let stale = TabReducer.reduce(tab, .monitorValidationFailed(tab.monitorGeneration.next(), .notFound), context: context)
        XCTAssertEqual(stale.0.snapshot.id, tab.snapshot.id); XCTAssertTrue(stale.1.isEmpty)
        let current = TabReducer.reduce(tab, .monitorValidationFailed(tab.monitorGeneration, .notFound), context: context)
        XCTAssertTrue(current.1.isEmpty)
        if case .failed(.notFound, attempted: .directory(root)) = current.0.snapshot.phase {} else {
            XCTFail("Expected a visible terminal failure")
        }
    }
}
@MainActor private final class K34ValidationRunner: EffectRunner {
    var cancelled = 0
    var started = 0
    func run(_ effect: StoreEffect, send: @escaping @Sendable (WindowStoreAction) -> Void) -> StoreEffectCancellation? {
        guard case .tab(_, .validateNavigation) = effect else { return nil }
        started += 1
        return StoreEffectCancellation { self.cancelled += 1 }
    }
}
