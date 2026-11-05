// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

private struct StoreFixedClock: HelmClock {
    let date: Date
    func now() -> Date { date }
}

@MainActor private final class RecordingStoreRunner: EffectRunner {
    var effects: [StoreEffect] = []
    var cancelled: [Generation] = []
    var hook: ((StoreEffect, @escaping @Sendable (WindowStoreAction) -> Void) -> Void)?
    func run(_ effect: StoreEffect, send: @escaping @Sendable (WindowStoreAction) -> Void) -> StoreEffectCancellation? {
        effects.append(effect); hook?(effect, send)
        guard case .tab(_, let tabEffect) = effect else { return nil }
        let generation: Generation
        switch tabEffect {
        case .load(_, let value, _), .startSearch(_, let value), .startMonitor(_, let value): generation = value
        case .addressEditor(.requestCompletions(let request)): generation = request.generation
        default: return nil
        }
        return StoreEffectCancellation { [weak self] in self?.cancelled.append(generation) }
    }
}

final class WindowStoreTests: XCTestCase {
    @MainActor private func fixture() -> (WindowStore, RecordingStoreRunner, TabID) {
        let home = URL(fileURLWithPath: "/home/test")
        let tab = TabState(location: .directory(home), homeDirectory: home)
        let runner = RecordingStoreRunner()
        let store = WindowStore(window: WindowState(tabs: [tab.id], activeTabID: tab.id), tabs: [tab], runner: runner,
                                clock: StoreFixedClock(date: Date(timeIntervalSince1970: 123)),
                                context: ReducerContext(now: .distantPast, homeDirectory: home))
        return (store, runner, tab.id)
    }

    func testFIFOFromSubscriberNeverRecursesAndPublishesNoOps() async {
        await MainActor.run {
            let (store, _, _) = fixture()
            var received: [UInt64] = []
            var nestedSequence: UInt64 = 0
            _ = store.snapshots.subscribe { snapshot in
                received.append(snapshot.sequence)
                if snapshot.sequence == 1 {
                    store.send(.window(.setSidebarVisible(true)))
                    nestedSequence = store.state.sequence
                }
            }
            store.send(.window(.setSidebarVisible(false)))
            store.send(.window(.setSidebarVisible(true)))
            XCTAssertEqual(received, [1, 2, 3]); XCTAssertEqual(nestedSequence, 1)
            XCTAssertTrue(store.state.window.isSidebarVisible)
        }
    }

    func testEffectCallbackQueuesUntilAllEffectsFinish() async {
        await MainActor.run {
            let (store, runner, id) = fixture()
            var sequenceDuringCallback: UInt64 = 0
            runner.hook = { effect, send in
                if case .tab(_, .load(let location, let generation, _)) = effect {
                    send(.tab(id, .loadFinished(generation, PresentationSnapshot(location: location))))
                    sequenceDuringCallback = store.state.sequence
                }
            }
            let target = Location.directory(URL(fileURLWithPath: "/next"))
            store.send(.tab(id, .navigate(target, .push)))
            XCTAssertEqual(sequenceDuringCallback, 1)
            XCTAssertEqual(store.state.sequence, 2)
            XCTAssertEqual(store.state.tabs[id]?.location, target)
            XCTAssertEqual(store.state.tabs[id]?.history.back.count, 1)
        }
    }

    func testSubscriberCancellationAndSnapshotIsolation() async {
        await MainActor.run {
            let (store, _, _) = fixture()
            var first: [Bool] = []
            var second: [Bool] = []
            var secondToken: Broadcast<WindowStoreSnapshot>.Token?
            _ = store.snapshots.subscribe { value in
                first.append(value.window.isSidebarVisible)
                if let token = secondToken { store.snapshots.cancel(token) }
                if value.sequence == 1 { store.send(.window(.setSidebarVisible(true))) }
            }
            secondToken = store.snapshots.subscribe { second.append($0.window.isSidebarVisible) }
            let captured = store.state
            store.send(.window(.setSidebarVisible(false)))
            XCTAssertEqual(first, [false, true]); XCTAssertTrue(second.isEmpty)
            XCTAssertTrue(captured.window.isSidebarVisible); XCTAssertEqual(captured.sequence, 0)
        }
    }

    func testSupersededLoadCancelsAndLateResultCannotCommit() async {
        await MainActor.run {
            let (store, runner, id) = fixture()
            let old = Location.directory(URL(fileURLWithPath: "/old"))
            let new = Location.directory(URL(fileURLWithPath: "/new"))
            store.send(.tab(id, .navigate(old, .push)))
            let generation = store.state.tabs[id]?.loadGeneration ?? Generation()
            store.send(.tab(id, .navigate(new, .push)))
            XCTAssertEqual(runner.cancelled, [generation])
            store.send(.tab(id, .loadFinished(generation, PresentationSnapshot(location: old))))
            XCTAssertEqual(store.state.tabs[id]?.pendingNavigation?.target, new)
            XCTAssertEqual(store.state.tabs[id]?.history.back.count, 0)
        }
    }

    func testSearchStopAndTabDisposalCancelOwnedEffects() async {
        await MainActor.run {
            let (store, runner, id) = fixture()
            let home = URL(fileURLWithPath: "/home/test")
            let query = SearchQuery(text: "file", scope: .home, bookmarkPaths: [], homeDirectory: home, lastDirectory: nil, showHidden: false, limit: 100)
            store.send(.tab(id, .searchStarted(query)))
            let generation = store.state.tabs[id]?.searchGeneration ?? Generation()
            store.send(.tab(id, .searchEnded))
            XCTAssertEqual(runner.cancelled, [generation])
            let other = TabState(location: .directory(home), homeDirectory: home)
            store.send(.addTab(other, activate: false))
            store.send(.tab(other.id, .refresh))
            let count = runner.cancelled.count
            store.send(.window(.closeTab(other.id)))
            XCTAssertNil(store.state.tabs[other.id]); XCTAssertEqual(runner.cancelled.count, count + 1)
            store.send(.tab(other.id, .refresh))
            XCTAssertNil(store.state.tabs[other.id])
        }
    }

    func testShutdownIsIdempotentAndRejectsLateCallbacks() async {
        await MainActor.run {
            let (store, runner, id) = fixture()
            store.send(.tab(id, .refresh))
            let active = store.state.tabs[id]
            store.send(.shutdown)
            XCTAssertEqual(runner.cancelled, [active?.loadGeneration, active?.monitorGeneration].compactMap { $0 })
            let finalSequence = store.state.sequence
            XCTAssertEqual(runner.cancelled.count, 2)
            store.send(.shutdown); store.enqueue(.tab(id, .refresh)); store.drain()
            XCTAssertEqual(store.state.sequence, finalSequence)
            XCTAssertEqual(runner.cancelled.count, 2)
        }
    }

    func testTenThousandQueuedActionsAreOrderedAndDeterministic() async {
        await MainActor.run {
            let (store, _, _) = fixture()
            var values: [UInt64] = []
            _ = store.snapshots.subscribe { snapshot in
                values.append(snapshot.sequence)
                XCTAssertEqual(snapshot.timestamp, Date(timeIntervalSince1970: 123))
                XCTAssertEqual(snapshot.window.isSidebarVisible, snapshot.sequence % 2 == 1)
            }
            for index in 0..<10_000 { store.enqueue(.window(.setSidebarVisible(index % 2 == 0))) }
            XCTAssertEqual(store.state.sequence, 0)
            store.drain()
            XCTAssertEqual(values, Array(UInt64(1)...UInt64(10_000)))
            let (replay, _, _) = fixture()
            for index in 0..<10_000 { replay.send(.window(.setSidebarVisible(index % 2 == 0))) }
            XCTAssertEqual(replay.state.sequence, store.state.sequence)
            XCTAssertEqual(replay.state.window.isSidebarVisible, store.state.window.isSidebarVisible)
        }
    }

    func testConcurrentProducersLoseNoActionsAndPreserveProducerOrder() async {
        let fixtureValue = await MainActor.run { fixture() }
        let store = fixtureValue.0
        // Distinct tabs expose each producer's ordering independently of inter-producer admission order.
        let ids = await MainActor.run { () -> [TabID] in
            let home = URL(fileURLWithPath: "/home/test")
            return (0..<4).map { _ in
                let tab = TabState(location: .directory(home), homeDirectory: home)
                store.send(.addTab(tab, activate: false)); return tab.id
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    for index in 0..<250 { store.enqueue(.tab(id, .setViewMode(index % 2 == 0 ? .grid : .list))) }
                }
            }
        }
        await MainActor.run {
            store.drain()
            XCTAssertEqual(store.state.sequence, 1004)
            for id in ids { XCTAssertEqual(store.state.tabs[id]?.viewMode, .list) }
        }
    }

    func testHistoryBackForwardAndFailedNavigation() async {
        await MainActor.run {
            let (store, runner, id) = fixture()
            let entry = FileEntry(url: URL(fileURLWithPath: "/home/test/selected"))
            runner.hook = { effect, send in
                if case .tab(_, .load(let location, let generation, _)) = effect {
                    send(.tab(id, .loadFinished(generation, PresentationSnapshot(location: location, sortedEntries: [entry]))))
                }
            }
            store.send(.tab(id, .refresh))
            store.send(.tab(id, .setSelection([entry.id], source: .user)))
            let origin = store.state.tabs[id]?.location
            let next = Location.directory(URL(fileURLWithPath: "/next"))
            store.send(.tab(id, .navigate(next, .push)))
            store.send(.tab(id, .goBack))
            XCTAssertEqual(store.state.tabs[id]?.location, origin)
            XCTAssertEqual(store.state.tabs[id]?.selection, [entry.id])
            store.send(.tab(id, .goForward))
            XCTAssertEqual(store.state.tabs[id]?.location, next)
            let history = store.state.tabs[id]?.history
            runner.hook = { effect, send in
                if case .tab(_, .load(_, let generation, _)) = effect { send(.tab(id, .loadFailed(generation, .permissionDenied))) }
            }
            store.send(.tab(id, .navigate(.trash, .push)))
            XCTAssertEqual(store.state.tabs[id]?.location, next)
            XCTAssertEqual(store.state.tabs[id]?.history, history)
        }
    }

    func testPersistSessionUsesDeliveredSnapshotAndInjectedClock() async {
        await MainActor.run {
            let (store, runner, _) = fixture()
            store.send(.persistSession)
            guard case .persistSession(let snapshot) = runner.effects.last else { return XCTFail("Missing persistence request") }
            XCTAssertEqual(snapshot.sequence, 1)
            XCTAssertEqual(snapshot.timestamp, Date(timeIntervalSince1970: 123))
            XCTAssertEqual(snapshot.window, store.state.window)
        }
    }

    func testTabActivationAndMissingValuesNormalization() async {
        await MainActor.run {
            let (store, _, initial) = fixture()
            let added = TabID()
            store.send(.window(.add(added, activate: true)))
            XCTAssertEqual(store.state.window.activeTabID, added)
            XCTAssertEqual(store.state.tabs[initial]?.isActive, false)
            XCTAssertEqual(store.state.tabs[added]?.isActive, true)
            store.send(.window(.closeCurrentTab))
            XCTAssertEqual(store.state.window.activeTabID, initial)
            XCTAssertEqual(store.state.tabs[initial]?.isActive, true)
            store.send(.window(.closeTab(initial)))
            XCTAssertEqual(store.state.window.tabs, [initial])
        }
    }

    func testCancellationHandleIsReentrancySafe() async {
        await MainActor.run {
            var count = 0
            var handle: StoreEffectCancellation?
            handle = StoreEffectCancellation { count += 1; handle?.cancel() }
            handle?.cancel(); handle?.cancel()
            XCTAssertEqual(count, 1)
        }
    }

    func testBothSubscribersSeeSameValuesDuringNestedDelivery() async {
        await MainActor.run {
            let (store, _, _) = fixture()
            var first: [UInt64] = []
            var second: [UInt64] = []
            _ = store.snapshots.subscribe { snapshot in
                first.append(snapshot.sequence)
                if snapshot.sequence == 1 { store.send(.persistSession) }
            }
            _ = store.snapshots.subscribe { second.append($0.sequence) }
            XCTAssertTrue(first.isEmpty); XCTAssertTrue(second.isEmpty)
            store.send(.persistSession)
            XCTAssertEqual(first, [1, 2]); XCTAssertEqual(second, first)
        }
    }

    func testConstructorNormalizesMissingExtraAndDuplicateTabs() async {
        await MainActor.run {
            let home = URL(fileURLWithPath: "/home")
            let first = TabState(location: .recent, homeDirectory: home)
            var duplicate = first; duplicate.location = .trash
            let extra = TabState(location: .trash, homeDirectory: home)
            let missing = TabID()
            let runner = RecordingStoreRunner()
            let store = WindowStore(window: WindowState(tabs: [first.id, missing], activeTabID: missing),
                                    tabs: [first, duplicate, extra], runner: runner,
                                    context: ReducerContext(now: .distantPast, homeDirectory: home))
            XCTAssertEqual(store.state.tabs.count, 2)
            XCTAssertNil(store.state.tabs[extra.id])
            XCTAssertEqual(store.state.tabs[first.id]?.location, .recent)
            XCTAssertEqual(store.state.tabs[first.id]?.isActive, false)
            XCTAssertEqual(store.state.tabs[missing]?.location, .directory(home))
            XCTAssertEqual(store.state.tabs[missing]?.isActive, true)
            XCTAssertTrue(runner.effects.isEmpty)
        }
    }

    func testCompletionAndMonitorCancellationStayIndependentOfLoad() async {
        await MainActor.run {
            let (store, runner, id) = fixture()
            store.send(.tab(id, .deactivated))
            store.send(.tab(id, .activated))
            store.send(.tab(id, .refresh))
            store.send(.tab(id, .addressBar(.beginEditing)))
            let before = runner.cancelled.count
            store.send(.tab(id, .addressBar(.textChanged("/home/te"))))
            XCTAssertGreaterThan(runner.cancelled.count, before)
            XCTAssertEqual(store.state.tabs[id]?.isLoading, true)
            let completionCount = runner.cancelled.count
            store.send(.tab(id, .deactivated))
            XCTAssertEqual(runner.cancelled.count, completionCount + 1)
            XCTAssertEqual(store.state.tabs[id]?.isLoading, true)
            store.send(.shutdown)
            XCTAssertGreaterThan(runner.cancelled.count, completionCount + 1)
        }
    }

    func testSameContentMonitorSnapshotsStillPublishNewPresentationIDs() async {
        await MainActor.run {
            let (store, _, id) = fixture()
            guard let tab = store.state.tabs[id] else { return XCTFail("Missing tab") }
            let snapshot = PresentationSnapshot(location: tab.location)
            var revisions: [UInt64] = []
            _ = store.snapshots.subscribe { value in
                if let revision = value.tabs[id]?.snapshot.revision { revisions.append(revision) }
            }
            store.send(.tab(id, .monitorSnapshot(tab.monitorGeneration, snapshot)))
            store.send(.tab(id, .monitorSnapshot(tab.monitorGeneration, snapshot)))
            XCTAssertEqual(revisions, [1, 2])
        }
    }

}
