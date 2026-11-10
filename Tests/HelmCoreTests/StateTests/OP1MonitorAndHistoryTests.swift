// DRAFT: pending review, 2026-11-05
import Foundation
import XCTest
@testable import HelmCore

/// FB2-6, FB2-7, FB2-8: repeated history presses and monitor recovery.
final class OP1MonitorAndHistoryTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/root")
    private func place(_ name: String) -> Location { .directory(URL(fileURLWithPath: "/" + name)).canonicalNavigationLocation }
    private var context: ReducerContext { ReducerContext(now: .distantPast, homeDirectory: root) }
    @discardableResult private func send(_ action: TabAction, _ state: inout TabState) -> [TabEffect] {
        let (next, effects) = TabReducer.reduce(state, action, context: context)
        state = next
        return effects
    }
    private func commit(_ state: inout TabState) {
        let target = state.pendingNavigation?.target ?? state.location
        send(.loadFinished(state.loadGeneration, PresentationSnapshot(location: target)), &state)
    }
    private func isFailed(_ state: TabState) -> Bool {
        if case .failed = state.snapshot.phase { return true }
        return false
    }

    // MARK: FB2-6

    func testDoubleBackBeforeFirstBatchMovesTwoSteps() {
        let history = NavigationHistory(back: [.init(location: place("x")), .init(location: place("y"))])
        var state = TabState(location: place("z"), homeDirectory: root, history: history)
        send(.goBack, &state)
        send(.goBack, &state)
        XCTAssertEqual(state.pendingNavigation?.target, place("x"))
        XCTAssertEqual(state.history, history, "History must not move before commit (B-069)")
        commit(&state)
        XCTAssertEqual(state.location, place("x"))
        XCTAssertTrue(state.history.back.isEmpty)
        XCTAssertEqual(state.history.forward.map(\.location), [place("z"), place("y")])
    }
    func testDoubleForwardBeforeFirstBatchMovesTwoSteps() {
        let history = NavigationHistory(forward: [.init(location: place("x")), .init(location: place("y"))])
        var state = TabState(location: place("z"), homeDirectory: root, history: history)
        send(.goForward, &state)
        send(.goForward, &state)
        commit(&state)
        XCTAssertEqual(state.location, place("x"))
        XCTAssertTrue(state.history.forward.isEmpty)
        XCTAssertEqual(state.history.back.map(\.location), [place("z"), place("y")])
    }
    func testBackPastTheOldestEntryKeepsThePendingTarget() {
        let history = NavigationHistory(back: [.init(location: place("y"))])
        var state = TabState(location: place("z"), homeDirectory: root, history: history)
        send(.goBack, &state)
        let pending = state.pendingNavigation
        XCTAssertTrue(send(.goBack, &state).isEmpty)
        XCTAssertEqual(state.pendingNavigation, pending)
    }
    func testFailedDoubleBackLeavesHistoryAndLocation() {
        let history = NavigationHistory(back: [.init(location: place("x")), .init(location: place("y"))])
        var state = TabState(location: place("z"), homeDirectory: root, history: history)
        send(.goBack, &state)
        send(.goBack, &state)
        send(.loadFailed(state.loadGeneration, .permissionDenied), &state)
        XCTAssertEqual(state.history, history)
        XCTAssertEqual(state.location, place("z"))
    }
    func testBackAfterPendingPushIsASingleStep() {
        let history = NavigationHistory(back: [.init(location: place("x")), .init(location: place("y"))])
        var state = TabState(location: place("z"), homeDirectory: root, history: history)
        send(.navigate(place("w"), .push), &state)
        send(.goBack, &state)
        XCTAssertEqual(state.pendingNavigation?.target, place("y"))
        XCTAssertEqual(state.pendingNavigation?.steps, 1)
    }

    // MARK: FB2-7

    func testRetryingStopPublishesNoFailureAndReconcilesOnRecovery() {
        var state = TabState(location: .directory(root), homeDirectory: root)
        let generation = state.monitorGeneration
        XCTAssertTrue(send(.monitorStopped(generation, .other("transient"), retrying: true), &state).isEmpty)
        XCTAssertFalse(state.monitorDegraded)
        XCTAssertFalse(isFailed(state), "A retry window must not flash a failed listing")
        XCTAssertEqual(send(.monitorWatching(generation), &state), [.refreshPaths([], generation)])
    }
    func testExhaustedStopStillDegradesVisibly() {
        var state = TabState(location: .directory(root), homeDirectory: root)
        send(.monitorStopped(state.monitorGeneration, .other("gone"), retrying: false), &state)
        XCTAssertTrue(state.monitorDegraded)
        XCTAssertTrue(isFailed(state))
    }
    func testRootEventDuringRetryWindowValidatesAfterRecovery() {
        var state = TabState(location: .directory(root), homeDirectory: root)
        let generation = state.monitorGeneration
        send(.monitorStopped(generation, .other("transient"), retrying: true), &state)
        XCTAssertTrue(send(.monitorEvent(generation, .rootChanged), &state).isEmpty,
                      "The adapter has no watch yet and would drop this read, leaving validation stuck")
        XCTAssertEqual(send(.monitorWatching(generation), &state), [.validateNavigation(.directory(root), generation)])
    }

    // MARK: FB2-8

    func testRepeatedRootEventsDoNotRestartASlowValidation() {
        var state = TabState(location: .directory(root), homeDirectory: root)
        let generation = state.monitorGeneration
        XCTAssertEqual(send(.monitorEvent(generation, .rootChanged), &state), [.validateNavigation(.directory(root), generation)])
        for _ in 0..<3 {
            XCTAssertTrue(send(.monitorEvent(generation, .rootChanged), &state).isEmpty,
                          "Each flush repeats the root event; restarting here never lets the read finish")
        }
        let completion = send(.monitorWorkCompleted(generation, request: state.monitorWorkGeneration,
                                                    .success(PresentationSnapshot(location: .directory(root)))), &state)
        XCTAssertTrue(completion.contains(.startMonitor(.directory(root), state.monitorGeneration)))
        XCTAssertEqual(completion.filter { if case .validateNavigation = $0 { return true } else { return false } }.count, 1,
                       "Exactly one follow-up validation")
    }
    func testRootEventDuringForegroundLoadDefersValidation() {
        var state = TabState(location: .directory(root), homeDirectory: root)
        send(.refresh, &state)
        XCTAssertTrue(send(.monitorEvent(state.monitorGeneration, .rootChanged), &state).isEmpty)
        commit(&state)
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.monitorValidationPending, "Finishing the load replays the deferred validation")
    }
    func testUnavailableAndValidationFailureDoNotOverwriteAForegroundLoad() {
        var state = TabState(location: .directory(root), homeDirectory: root)
        send(.refresh, &state)
        send(.monitorEvent(state.monitorGeneration, .unavailable(.unavailable)), &state)
        XCTAssertFalse(isFailed(state))
        send(.monitorValidationFailed(state.monitorGeneration, .other("late")), &state)
        XCTAssertFalse(isFailed(state))
    }
    func testRootEventOnDegradedWatchEmitsNoDroppedValidation() {
        var state = TabState(location: .directory(root), homeDirectory: root)
        let generation = state.monitorGeneration
        send(.monitorStopped(generation, .other("gone"), retrying: false), &state)
        XCTAssertTrue(send(.monitorEvent(generation, .rootChanged), &state).isEmpty)
        XCTAssertFalse(state.monitorValidationPending, "No adapter will answer, so nothing may be left pending")
    }
}
