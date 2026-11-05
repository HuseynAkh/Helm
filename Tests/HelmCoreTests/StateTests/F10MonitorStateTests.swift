// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class F10MonitorStateTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/a")
    private var context: ReducerContext { ReducerContext(now: .distantPast, homeDirectory: root) }
    @discardableResult private func send(_ action: TabAction, _ state: inout TabState) -> [TabEffect] {
        let result = TabReducer.reduce(state, action, context: context)
        state = result.0
        return result.1
    }
    func testFailedStagingReconcilesRetainedDirectoryExactlyOnce() {
        for alreadyDirty in [false, true] {
            for failedSnapshot in [false, true] {
                var state = TabState(location: .directory(root), homeDirectory: root)
                state.monitorDirty = alreadyDirty
                let history = state.history
                let target = Location.directory(URL(fileURLWithPath: "/b", isDirectory: true))
                send(.navigate(target, .push), &state)
                if !alreadyDirty {
                    XCTAssertTrue(send(.monitorEvent(state.monitorGeneration, .rescan), &state).isEmpty)
                }
                let action: TabAction = failedSnapshot
                    ? .loadFinished(state.loadGeneration, PresentationSnapshot(location: target, phase: .failed(.timedOut, attempted: target)))
                    : .loadFailed(state.loadGeneration, .timedOut)
                XCTAssertEqual(send(action, &state), [.refreshPaths([], state.monitorGeneration)])
                XCTAssertEqual(state.location, .directory(root))
                XCTAssertEqual(state.history, history)
                XCTAssertTrue(send(action, &state).isEmpty)
            }
        }
    }
    func testStagedRootInvalidationTakesPriorityAndRetiredEventsStayRejected() {
        var state = TabState(location: .directory(root), homeDirectory: root)
        send(.navigate(.directory(URL(fileURLWithPath: "/b")), .push), &state)
        let stale = state.monitorGeneration.next()
        send(.monitorEvent(stale, .rootChanged), &state)
        XCTAssertFalse(state.monitorDirty)
        for event in [MonitorEvent.rootChanged, .rescan] {
            XCTAssertTrue(send(.monitorEvent(state.monitorGeneration, event), &state).isEmpty)
        }
        XCTAssertEqual(send(.loadFailed(state.loadGeneration, .timedOut), &state),
                       [.validateNavigation(.directory(root), state.monitorGeneration)])
    }
    func testCleanActivationStartsWatchBeforeReconciliationAndAcceptsNewIDs() {
        var state = TabState(location: .directory(root), homeDirectory: root)
        let old = FileEntry(url: root.appendingPathComponent("old"))
        let new = FileEntry(url: root.appendingPathComponent("new"))
        send(.monitorSnapshot(state.monitorGeneration, SnapshotBuilder.build(location: state.location, entries: [old])), &state)
        send(.deactivated, &state)
        XCTAssertEqual(send(.activated, &state), [.startMonitor(state.location, state.monitorGeneration), .refreshPaths([], state.monitorGeneration)])
        send(.monitorSnapshot(state.monitorGeneration, SnapshotBuilder.build(location: state.location, entries: [new])), &state)
        XCTAssertEqual(state.snapshot.sortedIDs, [new.id])
        XCTAssertTrue(send(.activated, &state).isEmpty)
    }
    func testActivationReconciliationWaitsForForegroundLoad() {
        var state = TabState(location: .directory(root), homeDirectory: root)
        send(.refresh, &state)
        send(.deactivated, &state)
        XCTAssertEqual(send(.activated, &state), [.startMonitor(state.location, state.monitorGeneration)])
        XCTAssertEqual(send(.loadFinished(state.loadGeneration, PresentationSnapshot(location: state.location)), &state),
                       [.refreshPaths([], state.monitorGeneration)])
    }
}
