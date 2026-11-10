import Foundation
import XCTest
@testable import HelmCore

/// A place that couldn't open shows a card in place of the folder it was opened from. The folder's monitor keeps
/// the listing behind the card current, but never takes the card down: only going somewhere does.
final class CardUnderMonitorTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    private var context: ReducerContext { ReducerContext(now: .distantPast, homeDirectory: home) }
    @discardableResult private func send(_ action: TabAction, _ state: inout TabState) -> [TabEffect] {
        let result = TabReducer.reduce(state, action, context: context)
        state = result.0
        return result.1
    }
    private func listing(_ names: [String]) -> PresentationSnapshot {
        SnapshotBuilder.build(location: .directory(documents), entries: names.map { FileEntry(url: documents.appendingPathComponent($0)) })
    }
    /// Documents listed, then the Trash refused while opening it from there.
    private func listed() -> TabState {
        var state = TabState(location: .directory(documents), homeDirectory: home)
        send(.navigate(.directory(documents), .restore), &state)
        send(.loadFinished(state.loadGeneration, listing(["a.txt"])), &state)
        return state
    }
    private func refusedTrash() -> TabState {
        var state = listed()
        send(.navigate(.trash, .push), &state)
        send(.loadFailed(state.loadGeneration, .permissionDenied), &state)
        return state
    }
    private func isTrashCard(_ state: TabState) -> Bool {
        if case .failed(.permissionDenied, .trash) = state.snapshot.phase { return true }
        return false
    }

    func testAChangeInTheFolderUnderneathKeepsTheCard() {
        var state = refusedTrash()
        XCTAssertTrue(isTrashCard(state))
        send(.monitorSnapshot(state.monitorGeneration, listing(["a.txt", "b.txt"])), &state)
        XCTAssertTrue(isTrashCard(state), "a download finishing in Documents mustn't swap the card for Documents")
        // The listing behind it is current, for when you go back.
        XCTAssertEqual(state.snapshot.sortedEntries.map(\.name), ["a.txt", "b.txt"])
        // A problem with the folder underneath waits until you go back to it.
        send(.monitorEvent(state.monitorGeneration, .unavailable(.unavailable)), &state)
        XCTAssertTrue(isTrashCard(state))
        send(.monitorValidationFailed(state.monitorGeneration, .other("notFound")), &state)
        XCTAssertTrue(isTrashCard(state))
    }

    func testSwitchingTabsAwayAndBackKeepsTheCard() {
        var state = refusedTrash()
        send(.deactivated, &state)
        let effects = send(.activated, &state)
        XCTAssertTrue(effects.contains(.refreshPaths([], state.monitorGeneration)))
        send(.monitorSnapshot(state.monitorGeneration, listing(["a.txt"])), &state)
        XCTAssertTrue(isTrashCard(state))
    }

    func testGoingBackToTheFolderTakesTheCardDown() {
        var state = refusedTrash()
        // Back from the card: the folder it covered shows at once, then reloads.
        send(.returnToListing, &state)
        XCTAssertEqual(state.snapshot.phase, .ready)
        XCTAssertEqual(state.snapshot.sortedEntries.map(\.name), ["a.txt"])
        send(.refresh, &state)
        send(.loadFinished(state.loadGeneration, listing(["a.txt"])), &state)
        XCTAssertEqual(state.snapshot.phase, .ready)
        XCTAssertEqual(state.location, .directory(documents))
    }

    func testTheFolderOnShowStillClearsItsOwnProblems() {
        // Without a card about another place, monitor results show as they always have.
        var state = listed()
        send(.monitorEvent(state.monitorGeneration, .unavailable(.unavailable)), &state)
        if case .failed(_, let attempted) = state.snapshot.phase { XCTAssertEqual(attempted, .directory(documents)) }
        else { XCTFail("the folder's own watch problem shows") }
        send(.monitorSnapshot(state.monitorGeneration, listing(["a.txt"])), &state)
        XCTAssertEqual(state.snapshot.phase, .ready)
    }
}
