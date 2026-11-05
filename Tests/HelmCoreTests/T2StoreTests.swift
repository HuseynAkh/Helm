// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmTestKit

@MainActor private final class T2Runner: EffectRunner {
    var effects: [StoreEffect] = []
    var cancellations = 0
    func run(_ effect: StoreEffect, send: @escaping @Sendable (WindowStoreAction) -> Void) -> StoreEffectCancellation? {
        effects.append(effect)
        if case .tab(_, .load) = effect { return StoreEffectCancellation { self.cancellations += 1 } }
        return nil
    }
}
// F-002/F-005 and B-014: delivery must equal pure reduction regardless of admission batching.
final class T2StoreTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/t2")
    @MainActor private func fixture() -> (WindowStore, T2Runner, TabState) {
        let tab = TabState(location: .directory(root), homeDirectory: root)
        let runner = T2Runner()
        let store = WindowStore(window: WindowState(tabs: [tab.id], activeTabID: tab.id), tabs: [tab], runner: runner,
                                clock: FakeClock(), context: ReducerContext(now: .distantPast, homeDirectory: root))
        return (store, runner, tab)
    }
    @MainActor private func property(seed: UInt64) {
        let (store, runner, initial) = fixture()
        var expected = initial
        var random = seed
        let context = ReducerContext(now: FakeClock().now(), homeDirectory: root)
        var expectedEffects: [TabEffect] = []
        for i in 0..<500 {
            random = random &* 6364136223846793005 &+ 1442695040888963407
            let action: TabAction
            switch (random >> 32) % 12 {
            case 0: action = .setViewMode(.list)
            case 1: action = .setViewMode(.grid)
            case 2: action = .toggleHidden
            case 3: action = .refresh
            case 4: action = .loadFinished(expected.loadGeneration, PresentationSnapshot(location: expected.pendingNavigation?.target ?? expected.location))
            case 5: action = .loadFailed(expected.loadGeneration, .timedOut)
            case 6: action = .navigate(.directory(root.appendingPathComponent(String(i % 7))), .push)
            case 7: action = .goBack
            case 8: action = .goForward
            case 9: action = .monitorEvent(expected.monitorGeneration, .rescan)
            case 10: action = .deactivated
            default: action = .activated
            }
            let next = TabReducer.reduce(expected, action, context: context)
            expected = next.0; expectedEffects += next.1
            store.enqueue(.tab(initial.id, action))
            if i % 17 == 0 { store.drain(); XCTAssertEqual(store.state.tabs[initial.id], expected, "seed \(seed), step \(i)") }
        }
        store.drain()
        XCTAssertEqual(store.state.tabs[initial.id], expected)
        XCTAssertEqual(store.state.sequence, 500)
        let actual = runner.effects.compactMap { effect -> TabEffect? in if case .tab(_, let value) = effect { return value }; return nil }
        XCTAssertEqual(actual, expectedEffects)
    }
    @MainActor
    func testReducerEquivalenceSeed1() async throws {
        property(seed: 1)
    }
    @MainActor
    func testReducerEquivalenceSeed7() async throws {
        property(seed: 7)
    }
    @MainActor
    func testReducerEquivalenceSeed42() async throws {
        property(seed: 42)
    }
    @MainActor
    func testReducerEquivalenceSeed103() async throws {
        property(seed: 103)
    }
    @MainActor
    func testReducerEquivalenceSeed65535() async throws {
        property(seed: 65535)
    }
    @MainActor
    func testReducerEquivalenceSeed999983() async throws {
        property(seed: 999983)
    }
    @MainActor
    func testReducerEquivalenceSeed123456789() async throws {
        property(seed: 123456789)
    }
    @MainActor
    func testReducerEquivalenceSeed18446744073709551615() async throws {
        property(seed: 18446744073709551615)
    }
    @MainActor
    func testQueuedShutdownDropsTail() async throws {
        let (s, _, _) = fixture(); s.enqueue(.persistSession); s.enqueue(.shutdown); s.enqueue(.persistSession); s.drain(); XCTAssertEqual(s.state.sequence, 2)
    }
    @MainActor
    func testNestedShutdownDropsNestedTail() async throws {
        let (s, _, _) = fixture(); _ = s.snapshots.subscribe { v in if v.sequence == 1 { s.send(.shutdown); s.send(.persistSession) } }; s.send(.persistSession); XCTAssertEqual(s.state.sequence, 2)
    }
    @MainActor
    func testObserverSeesAssignedState() async throws {
        let (s, _, _) = fixture(); var seen = 0; _ = s.snapshots.subscribe { v in XCTAssertEqual(s.state.sequence, v.sequence); seen += 1 }; s.send(.persistSession); XCTAssertEqual(seen, 1)
    }
    @MainActor
    func testUnknownTabPublishesWithoutInsertion() async throws {
        let (s, _, _) = fixture(); s.send(.tab(TabID(), .refresh)); XCTAssertEqual(s.state.tabs.count, 1); XCTAssertEqual(s.state.sequence, 1)
    }
    @MainActor
    func testDuplicateAddPreservesState() async throws {
        let (s, _, t) = fixture(); s.send(.tab(t.id, .setViewMode(.list))); s.send(.addTab(t, activate: true)); XCTAssertEqual(s.state.tabs.count, 1); XCTAssertEqual(s.state.tabs[t.id]?.viewMode, .list)
    }
    @MainActor
    func testCancelledLoadCannotCommit() async throws {
        let (s, r, t) = fixture(); s.send(.tab(t.id, .refresh)); let old = try XCTUnwrap(s.state.tabs[t.id]?.loadGeneration); s.send(.tab(t.id, .refresh)); XCTAssertEqual(r.cancellations, 1); s.send(.tab(t.id, .loadFinished(old, PresentationSnapshot(location: .trash)))); XCTAssertEqual(s.state.tabs[t.id]?.location, t.location); XCTAssertTrue(try XCTUnwrap(s.state.tabs[t.id]?.isLoading))
    }
    @MainActor
    func testCancelledFailureCannotTerminateNewLoad() async throws {
        let (s, _, t) = fixture(); s.send(.tab(t.id, .refresh)); let old = try XCTUnwrap(s.state.tabs[t.id]?.loadGeneration); s.send(.tab(t.id, .refresh)); s.send(.tab(t.id, .loadFailed(old, .permissionDenied))); XCTAssertTrue(try XCTUnwrap(s.state.tabs[t.id]?.isLoading))
    }
    @MainActor
    func testCloseCancelsOnce() async throws {
        let (s, r, _) = fixture(); let t = TabState(location: .recent, homeDirectory: root); s.send(.addTab(t, activate: false)); s.send(.tab(t.id, .refresh)); s.send(.window(.closeTab(t.id))); s.send(.window(.closeTab(t.id))); XCTAssertEqual(r.cancellations, 1); XCTAssertNil(s.state.tabs[t.id])
    }
    @MainActor
    func testShutdownCancelsOnce() async throws {
        let (s, r, t) = fixture(); s.send(.tab(t.id, .refresh)); s.send(.shutdown); s.send(.shutdown); XCTAssertEqual(r.cancellations, 1); XCTAssertEqual(s.state.sequence, 2)
    }
    @MainActor
    func testNoInitialReplay() async throws {
        let (s, _, _) = fixture(); var seen = 0; _ = s.snapshots.subscribe { _ in seen += 1 }; XCTAssertEqual(seen, 0); s.send(.persistSession); XCTAssertEqual(seen, 1)
    }
    @MainActor
    func testCancellationHandleRecursive() async throws {
        var count = 0; var handle: StoreEffectCancellation?; handle = StoreEffectCancellation { count += 1; handle?.cancel() }; handle?.cancel(); handle?.cancel(); XCTAssertEqual(count, 1)
    }
    @MainActor
    func testInactiveTabLoadIsolation() async throws {
        let (s, _, t) = fixture(); let other = TabState(location: .trash, homeDirectory: root); s.send(.addTab(other, activate: false)); s.send(.tab(other.id, .refresh)); XCTAssertFalse(try XCTUnwrap(s.state.tabs[t.id]?.isLoading)); XCTAssertTrue(try XCTUnwrap(s.state.tabs[other.id]?.isLoading))
    }
    @MainActor
    func testHundredThousandFIFO() async throws {
        let (s, _, _) = fixture(); var seen: UInt64 = 0; _ = s.snapshots.subscribe { v in seen += 1; XCTAssertEqual(v.sequence, seen); XCTAssertEqual(v.window.isSidebarVisible, seen % 2 == 1) }; for i in 0..<100_000 { s.enqueue(.window(.setSidebarVisible(i % 2 == 0))) }; s.drain(); XCTAssertEqual(seen, 100_000)
    }
    func testConcurrentProducersRetainPerTabOrder() async throws {
        let (s, _, _) = await fixture()
        let ids = await MainActor.run { (0..<8).map { _ -> TabID in
            let t = TabState(location: .recent, homeDirectory: root); s.send(.addTab(t, activate: false)); return t.id
        } }
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { for i in 0..<1000 { s.enqueue(.tab(id, .setViewMode(i % 2 == 0 ? .grid : .list))) } } }
        }
        await MainActor.run { s.drain(); XCTAssertEqual(s.state.sequence, 8008); for id in ids { XCTAssertEqual(s.state.tabs[id]?.viewMode, .list) } }
    }
    @MainActor
    func testRetiredMonitorAfterRefresh() async throws {
        let (s, _, t) = fixture()
        let old = t.monitorGeneration
        s.send(.tab(t.id, .refresh))
        let before = try XCTUnwrap(s.state.tabs[t.id])
        let stale = PresentationSnapshot(location: t.location, sortedEntries: [FileEntry(url: root.appendingPathComponent("stale"))])
        s.send(.tab(t.id, .monitorSnapshot(old, stale)))
        XCTAssertEqual(s.state.tabs[t.id]?.snapshot, before.snapshot)
        XCTAssertEqual(s.state.tabs[t.id]?.selection, before.selection)
    }
    @MainActor
    func testRetiredMonitorAfterHiddenToggle() async throws {
        let (s, _, t) = fixture()
        let old = t.monitorGeneration
        s.send(.tab(t.id, .toggleHidden))
        let before = try XCTUnwrap(s.state.tabs[t.id])
        let stale = PresentationSnapshot(location: t.location, sortedEntries: [FileEntry(url: root.appendingPathComponent("stale"))])
        s.send(.tab(t.id, .monitorSnapshot(old, stale)))
        XCTAssertEqual(s.state.tabs[t.id]?.snapshot, before.snapshot)
        XCTAssertEqual(s.state.tabs[t.id]?.selection, before.selection)
    }
    @MainActor
    func testRetiredMonitorAfterNavigation() async throws {
        let (s, _, t) = fixture()
        let old = t.monitorGeneration
        s.send(.tab(t.id, .navigate(.trash, .push)))
        let before = try XCTUnwrap(s.state.tabs[t.id])
        let stale = PresentationSnapshot(location: t.location, sortedEntries: [FileEntry(url: root.appendingPathComponent("stale"))])
        s.send(.tab(t.id, .monitorSnapshot(old, stale)))
        XCTAssertEqual(s.state.tabs[t.id]?.snapshot, before.snapshot)
        XCTAssertEqual(s.state.tabs[t.id]?.selection, before.selection)
    }
    @MainActor
    func testRetiredMonitorAfterDeactivate() async throws {
        let (s, _, t) = fixture()
        let old = t.monitorGeneration
        s.send(.tab(t.id, .deactivated))
        let before = try XCTUnwrap(s.state.tabs[t.id])
        let stale = PresentationSnapshot(location: t.location, sortedEntries: [FileEntry(url: root.appendingPathComponent("stale"))])
        s.send(.tab(t.id, .monitorSnapshot(old, stale)))
        XCTAssertEqual(s.state.tabs[t.id]?.snapshot, before.snapshot)
        XCTAssertEqual(s.state.tabs[t.id]?.selection, before.selection)
    }
}
