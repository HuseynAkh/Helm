// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore

final class K15StateAdversarialTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home")
    private var context: ReducerContext { ReducerContext(now: .distantPast, homeDirectory: home) }
    private func send(_ action: TabAction, _ state: inout TabState) {
        state = TabReducer.reduce(state, action, context: context).0
    }
    private func navigation(seed: UInt64) {
        var random = K15StateRandom(seed: seed)
        var state = TabState(location: .directory(home), homeDirectory: home)
        var retired: [Generation] = []
        for index in 0..<600 {
            let previous = state
            switch random.next(8) {
            case 0:
                retired.append(state.loadGeneration)
                send(.navigate(.directory(URL(fileURLWithPath: "/folder\(random.next(12))")), .push), &state)
                XCTAssertEqual(state.history, previous.history)
                XCTAssertEqual(state.location, previous.location)
            case 1: send(.goBack, &state)
            case 2: send(.goForward, &state)
            case 3:
                let target = state.pendingNavigation?.target ?? state.location
                let entries = (0..<random.next(8)).map { FileEntry(url: URL(fileURLWithPath: "/item\($0)")) }
                send(.loadFinished(state.loadGeneration, SnapshotBuilder.build(location: target, entries: entries)), &state)
            case 4:
                send(.loadFailed(state.loadGeneration, .permissionDenied), &state)
                XCTAssertEqual(state.history, previous.history)
                XCTAssertEqual(state.location, previous.location)
            case 5:
                if let stale = retired.first, stale != state.loadGeneration {
                    send(.loadFinished(stale, PresentationSnapshot(location: state.location)), &state)
                    send(.loadFailed(stale, .notFound), &state)
                    XCTAssertEqual(state, previous, "B-009 seed \(seed) step \(index)")
                }
            case 6: send(.setSelection([ItemID(rawValue: "/missing")], source: .user), &state)
            default: send(.refresh, &state)
            }
            XCTAssertEqual(state.snapshot.location, state.location, "B-069 seed \(seed) step \(index)")
            XCTAssertTrue(state.selection.isSubset(of: Set(state.snapshot.visibleIDs(expanding: state.expandedIDs))))
            XCTAssertEqual(Set(state.snapshot.sortedIDs).count, state.snapshot.sortedIDs.count)
            if let pending = state.pendingNavigation { XCTAssertEqual(pending.generation, state.loadGeneration); XCTAssertTrue(state.isLoading) }
        }
    }
    /// F-005/B-009/B-069: seeded navigation, failure and stale callback interleavings.
    func testNavigationSeed1() { navigation(seed: 1) }
    /// F-005/B-009/B-069: a different deterministic history and callback ordering.
    func testNavigationSeed42() { navigation(seed: 42) }
    /// F-005/B-009/B-069: wraparound arithmetic in the deterministic generator.
    func testNavigationSeedMax() { navigation(seed: UInt64.max) }
    /// F-005/B-019: history follows an independent stack model, including empty transitions.
    func testRandomHistoryAgainstReferenceModel() {
        var rng = K15StateRandom(seed: 90210)
        var history = NavigationHistory()
        var back: [NavigationHistory.Entry] = [], forward: [NavigationHistory.Entry] = []
        var current = NavigationHistory.Entry(location: .recent)
        for _ in 0..<2000 {
            switch rng.next(3) {
            case 0:
                let target: Location = .directory(URL(fileURLWithPath: "/\(rng.next(5))"))
                let changed = current.location != target
                XCTAssertEqual(history.push(current: current, movingTo: target), changed)
                if changed { back.append(current); forward.removeAll(); current = .init(location: target) }
            case 1:
                let actual = history.goBack(current: current), expected = back.popLast()
                XCTAssertEqual(actual, expected)
                if let expected { forward.append(current); current = expected }
            default:
                let actual = history.goForward(current: current), expected = forward.popLast()
                XCTAssertEqual(actual, expected)
                if let expected { back.append(current); current = expected }
            }
            XCTAssertEqual(history.back, back); XCTAssertEqual(history.forward, forward)
        }
    }
    /// F-004: arbitrary add/close/move actions never orphan the active tab.
    func testRandomWindowMembership() {
        var rng = K15StateRandom(seed: 123)
        let ids = (0..<12).map { _ in TabID() }
        var state = WindowState(tabs: [ids[0]], activeTabID: ids[0])
        for _ in 0..<1000 {
            let id = ids[rng.next(ids.count)]
            let action: WindowAction
            switch rng.next(4) {
            case 0: action = .add(id, activate: rng.next(2) == 0)
            case 1: action = .closeTab(id)
            case 2: action = .activate(id)
            default: action = .move(id, to: rng.next(20) - 4)
            }
            state = WindowReducer.reduce(state, action).0
            XCTAssertFalse(state.tabs.isEmpty); XCTAssertTrue(state.tabs.contains(state.activeTabID))
            XCTAssertEqual(Set(state.tabs).count, state.tabs.count)
        }
    }
    /// B-017/B-069: failure before the first batch preserves the committed history.
    func testDeniedInitialNavigation() { failed(.permissionDenied) }
    /// B-069: cancellation does not push a destination that never loaded.
    func testCancelledInitialNavigation() { failed(.cancelled) }
    /// B-107: timeout leaves the committed destination intact.
    func testTimedOutInitialNavigation() { failed(.timedOut) }
    /// B-069: missing destinations do not corrupt history.
    func testMissingInitialNavigation() { failed(.notFound) }
    private func failed(_ error: LoadError) {
        var state = TabState(location: .recent, homeDirectory: home)
        send(.navigate(.directory(home), .push), &state)
        send(.loadFailed(state.loadGeneration, error), &state)
        XCTAssertEqual(state.location, .recent); XCTAssertTrue(state.history.back.isEmpty)
        XCTAssertFalse(state.isLoading); XCTAssertNil(state.pendingNavigation)
    }
    /// B-009: callbacks after deactivation are ignored.
    func testInactiveMonitorCannotPublish() {
        var state = TabState(location: .recent, homeDirectory: home)
        send(.deactivated, &state)
        let before = state
        send(.monitorSnapshot(state.monitorGeneration, PresentationSnapshot(location: .recent)), &state)
        XCTAssertEqual(state, before)
    }
    /// F-005: history encoding retains selection in both stacks.
    func testHistoryCodableRoundTrip() throws {
        let entry = NavigationHistory.Entry(location: .directory(home), selection: [ItemID(rawValue: "/home/a")])
        let original = NavigationHistory(back: [entry], forward: [entry, .init(location: .trash)])
        XCTAssertEqual(try JSONDecoder().decode(NavigationHistory.self, from: JSONEncoder().encode(original)), original)
    }
    /// B-009: duplicate roots cannot produce duplicate visible identities.
    func testSnapshotDuplicateRoots() {
        let entry = FileEntry(url: home)
        let snapshot = PresentationSnapshot(location: .recent, sortedEntries: Array(repeating: entry, count: 5000))
        XCTAssertEqual(snapshot.sortedIDs, [entry.id]); XCTAssertEqual(snapshot.index(of: entry.id), 0)
    }
    /// F-037: negative root counts do not expose invalid rows.
    func testNegativeRootCountClamped() {
        let snapshot = PresentationSnapshot(location: .recent, sortedEntries: [FileEntry(url: home)], rootCount: -10)
        XCTAssertEqual(snapshot.rootCount, 0); XCTAssertTrue(snapshot.visibleIDs(expanding: []).isEmpty)
    }
    /// F-037: oversized root counts do not exceed available entries.
    func testOversizedRootCountClamped() {
        let snapshot = PresentationSnapshot(location: .recent, sortedEntries: [FileEntry(url: home)], rootCount: Int.max)
        XCTAssertEqual(snapshot.rootCount, 1); XCTAssertEqual(snapshot.visibleIDs(expanding: []).count, 1)
    }
    /// B-011: unknown selection IDs cannot enter a newly constructed tab.
    func testUnknownSelectionPruned() {
        var state = TabState(location: .recent, homeDirectory: home)
        send(.setSelection([ItemID(rawValue: "/unknown")], source: .user), &state)
        XCTAssertTrue(state.selection.isEmpty)
    }
    /// B-031: Recent and Trash have no directory mutation target after a real commit.
    func testVirtualCommitCannotRetainHomeMutationTarget() {
        for target: Location in [.recent, .trash] {
            var state = TabState(location: .directory(home), homeDirectory: home)
            send(.navigate(target, .push), &state)
            send(.loadFinished(state.loadGeneration, PresentationSnapshot(location: target)), &state)
            XCTAssertNil(state.mutationTarget)
        }
    }
}

private struct K15StateRandom {
    var seed: UInt64
    mutating func next(_ upper: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 32) % UInt64(upper))
    }
}
