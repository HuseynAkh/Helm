// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

/// F-008/F-025, B-013/B-017: staged failures retain history and reconcile once.
final class T3NavigationTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/old")
    @discardableResult private func send(_ action: TabAction, _ state: inout TabState) -> [TabEffect] {
        let result = TabReducer.reduce(state, action, context: ReducerContext(now: .distantPast, homeDirectory: root))
        state = result.0
        return result.1
    }
    private func failure(_ event: MonitorEvent, snapshotFailure: Bool, inactive: Bool) {
        var state = TabState(location: .directory(root), homeDirectory: root)
        let original = FileEntry(url: root.appendingPathComponent("retained"))
        state.snapshot = SnapshotBuilder.build(location: state.location, entries: [original])
        let history = state.history
        let target = Location.directory(URL(fileURLWithPath: "/unreadable"))
        send(.navigate(target, .push), &state)
        for _ in 0..<50 { XCTAssertTrue(send(.monitorEvent(state.monitorGeneration, event), &state).isEmpty) }
        XCTAssertEqual(state.snapshot.sortedIDs, [original.id])
        if inactive { send(.deactivated, &state) }
        let action: TabAction = snapshotFailure
            ? .loadFinished(state.loadGeneration, PresentationSnapshot(location: target, phase: .failed(.permissionDenied, attempted: target)))
            : .loadFailed(state.loadGeneration, .permissionDenied)
        let effects = send(action, &state)
        XCTAssertEqual(state.location, .directory(root)); XCTAssertEqual(state.history, history)
        XCTAssertEqual(state.snapshot.sortedIDs, [original.id])
        let validation: Bool
        switch event { case .rootChanged, .volumeUnmounted, .unavailable: validation = true; default: validation = false }
        if inactive {
            XCTAssertTrue(effects.isEmpty)
            let activation = send(.activated, &state)
            XCTAssertEqual(activation, [.startMonitor(state.location, state.monitorGeneration), validation ? .validateNavigation(state.location, state.monitorGeneration) : .refreshPaths([], state.monitorGeneration)])
        } else {
            XCTAssertEqual(effects, [validation ? .validateNavigation(state.location, state.monitorGeneration) : .refreshPaths([], state.monitorGeneration)])
        }
        XCTAssertTrue(send(action, &state).isEmpty)
        XCTAssertTrue(send(.activated, &state).isEmpty)
    }
    func testRescanFailure() { failure(.rescan, snapshotFailure: false, inactive: false) }
    func testChangedFailure() { failure(.changed(paths: ["/old/file"]), snapshotFailure: false, inactive: false) }
    func testRootFailure() { failure(.rootChanged, snapshotFailure: false, inactive: false) }
    func testUnmountFailureSnapshot() { failure(.volumeUnmounted, snapshotFailure: true, inactive: false) }
    func testInactiveRescanFailure() { failure(.rescan, snapshotFailure: false, inactive: true) }
    func testInactiveRootFailureSnapshot() { failure(.rootChanged, snapshotFailure: true, inactive: true) }
    func testSupersededStagingFailureCannotReconcileEarly() {
        var state = TabState(location: .directory(root), homeDirectory: root)
        send(.navigate(.directory(URL(fileURLWithPath: "/b")), .push), &state)
        let old = state.loadGeneration
        send(.monitorEvent(state.monitorGeneration, .rescan), &state)
        send(.navigate(.directory(URL(fileURLWithPath: "/c")), .push), &state)
        XCTAssertTrue(send(.loadFailed(old, .timedOut), &state).isEmpty)
        XCTAssertTrue(state.isLoading)
        XCTAssertEqual(send(.loadFailed(state.loadGeneration, .timedOut), &state), [.refreshPaths([], state.monitorGeneration)])
    }
    func testRepeatedActivationCyclesRejectRetiredSnapshots() {
        var state = TabState(location: .directory(root), homeDirectory: root)
        for _ in 0..<100 {
            let retired = state.monitorGeneration
            send(.deactivated, &state)
            XCTAssertEqual(send(.activated, &state), [.startMonitor(state.location, state.monitorGeneration), .refreshPaths([], state.monitorGeneration)])
            let before = state.snapshot.id
            send(.monitorSnapshot(retired, PresentationSnapshot(location: state.location)), &state)
            XCTAssertEqual(state.snapshot.id, before)
        }
    }
}
