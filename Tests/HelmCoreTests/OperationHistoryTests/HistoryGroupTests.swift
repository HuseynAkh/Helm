import XCTest
import HelmCore

/// Several operations run under one group are undone as one change: each entry is named after the group, and once
/// undone it is gone, since a redo would run one command of the group again without the checks the group passed.
final class HistoryGroupTests: XCTestCase {
    private let group = HistoryGroup(name: "Organize “Downloads”")

    @discardableResult
    private func forward(_ name: String, _ state: inout OperationHistoryState, outcome: HistoryOutcome = .succeeded) -> OperationID {
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginForward(request, name: name))
        return finish(request, &state, outcome: outcome)
    }
    @discardableResult
    private func groupedForward(_ group: HistoryGroup, _ state: inout OperationHistoryState,
                                outcome: HistoryOutcome = .succeeded) -> OperationID {
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginGroupedForward(request, group))
        return finish(request, &state, outcome: outcome)
    }
    private func finish(_ request: HistoryRequestID, _ state: inout OperationHistoryState, outcome: HistoryOutcome) -> OperationID {
        let operation = OperationID()
        OperationHistoryReducer.reduce(&state, .startForward(request, operation: operation))
        OperationHistoryReducer.reduce(&state, .finishForward(request, operation: operation, outcome: outcome))
        return operation
    }
    @discardableResult
    private func undo(_ state: inout OperationHistoryState, outcome: HistoryOutcome = .succeeded) -> [HistoryEffect] {
        let request = HistoryRequestID()
        let effects = OperationHistoryReducer.reduce(&state, .beginUndo(request))
        OperationHistoryReducer.reduce(&state, .startUndo(request, operation: OperationID()))
        OperationHistoryReducer.reduce(&state, .complete(request, outcome: outcome))
        return effects
    }

    /// The operation an undo was sent to reverse.
    private func undone(by effects: [HistoryEffect]) -> OperationID? {
        guard effects.count == 1, case .performUndo(_, let operation) = effects[0] else { return nil }
        return operation
    }

    func testAGroupHasAnIdentityOfItsOwn() {
        let other = HistoryGroup(name: group.name)
        XCTAssertNotEqual(group, other, "two plans with one title are two groups")
        XCTAssertEqual(HistoryGroup(id: group.id, name: group.name), group)
        XCTAssertEqual(Set([group, other, group]).count, 2)
    }

    func testAGroupedForwardNamesItsEntryAfterTheGroup() {
        var state = OperationHistoryState()
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginGroupedForward(request, group))
        XCTAssertEqual(state.pending, .forward(request, name: "Organize “Downloads”"), "reserved like any forward, under the group's name")
        XCTAssertEqual(state.undoAvailability, .busy)
        let operation = finish(request, &state, outcome: .succeeded)

        XCTAssertEqual(state.undoEntries, [HistoryEntry(operationID: operation, name: "Organize “Downloads”", group: group)])
        XCTAssertEqual(state.undoEntries.last?.group, group)
        XCTAssertEqual(state.undoAvailability, .available("Organize “Downloads”"), "Edit reads Undo Organize “Downloads”")
        XCTAssertEqual(state.lastOutcome, .succeeded)
    }

    func testEveryCommandOfAGroupCarriesItAndTheNextForwardDoesNot() {
        var state = OperationHistoryState()
        forward("Rename", &state)
        let first = groupedForward(group, &state)
        let second = groupedForward(group, &state)
        let later = forward("Copy", &state)

        XCTAssertEqual(state.undoEntries.map(\.name), ["Rename", "Organize “Downloads”", "Organize “Downloads”", "Copy"])
        XCTAssertEqual(state.undoEntries.map(\.group), [nil, group, group, nil])
        XCTAssertEqual(state.undoEntries.map(\.operationID).suffix(3), [first, second, later])
    }

    func testAnUndoneGroupedEntryIsNotOnTheRedoStack() {
        var state = OperationHistoryState()
        forward("Rename", &state)
        let first = groupedForward(group, &state)
        let second = groupedForward(group, &state)

        // The window undoes the top entry and goes on while the next one carries the same group.
        XCTAssertEqual(undone(by: undo(&state)), second, "the last command of the group is undone first")
        XCTAssertEqual(state.undoEntries.map(\.operationID).last, first)
        XCTAssertTrue(state.redoEntries.isEmpty)
        XCTAssertEqual(state.redoAvailability, .empty)
        XCTAssertEqual(state.undoAvailability, .available("Organize “Downloads”"), "the rest of the group is next")

        XCTAssertEqual(undone(by: undo(&state)), first)
        XCTAssertTrue(state.redoEntries.isEmpty, "an undone plan can't be redone")
        XCTAssertEqual(state.redoAvailability, .empty)
        XCTAssertEqual(state.undoAvailability, .available("Rename"), "the entry below the group is untouched")
        XCTAssertEqual(state.undoEntries.map(\.group), [nil])
        XCTAssertEqual(state.lastOutcome, .succeeded)

        // A redo has nothing to act on.
        OperationHistoryReducer.reduce(&state, .beginRedoForward(HistoryRequestID()))
        XCTAssertNil(state.pending)
    }

    func testEntriesWithoutAGroupBehaveAsBefore() {
        var state = OperationHistoryState()
        let rename = forward("Rename", &state)
        let copy = forward("Copy", &state)
        XCTAssertEqual(state.undoEntries, [HistoryEntry(operationID: rename, name: "Rename"), HistoryEntry(operationID: copy, name: "Copy")])
        XCTAssertEqual(state.undoEntries.map(\.group), [nil, nil])
        XCTAssertNil(HistoryEntry(operationID: copy, name: "Copy").group, "an entry is on its own unless a group is given")

        undo(&state)
        XCTAssertEqual(state.redoEntries, [HistoryEntry(operationID: copy, name: "Copy")])
        XCTAssertEqual(state.redoAvailability, .unsupported("Copy"))
        XCTAssertEqual(state.undoAvailability, .available("Rename"))

        // Redo runs the command again as a forward of its own.
        let redo = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginRedoForward(redo))
        XCTAssertEqual(state.pending, .forward(redo, name: "Copy"))
        let again = finish(redo, &state, outcome: .succeeded)
        XCTAssertEqual(state.undoEntries.last, HistoryEntry(operationID: again, name: "Copy"))
        XCTAssertTrue(state.redoEntries.isEmpty)
    }

    func testAnUngroupedEntryUndoneBeforeAGroupStaysOnTheRedoStack() {
        var state = OperationHistoryState()
        groupedForward(group, &state)
        let copy = forward("Copy", &state)
        undo(&state)
        XCTAssertEqual(state.redoEntries, [HistoryEntry(operationID: copy, name: "Copy")])
        undo(&state)
        XCTAssertEqual(state.redoEntries, [HistoryEntry(operationID: copy, name: "Copy")], "only the grouped entry is let go")
        XCTAssertTrue(state.undoEntries.isEmpty)
    }

    func testAGroupedForwardClearsRedoLikeAnyNewChange() {
        var state = OperationHistoryState()
        forward("Copy", &state)
        undo(&state)
        XCTAssertEqual(state.redoAvailability, .unsupported("Copy"))
        groupedForward(group, &state)
        XCTAssertEqual(state.redoAvailability, .empty)
    }

    func testTheGroupDoesNotLeakIntoTheNextForward() {
        var state = OperationHistoryState()
        // A grouped forward that never ran leaves no entry, and the forward after it is on its own.
        let aborted = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginGroupedForward(aborted, group))
        OperationHistoryReducer.reduce(&state, .abortForward(aborted, failure: .cancelled))
        XCTAssertTrue(state.undoEntries.isEmpty)
        XCTAssertNil(state.pending)
        forward("Copy", &state)
        XCTAssertEqual(state.undoEntries.map(\.group), [nil])

        // One that failed leaves no entry either.
        groupedForward(group, &state, outcome: .failed("No space"))
        XCTAssertEqual(state.undoEntries.map(\.name), ["Copy"])
        forward("Move", &state)
        XCTAssertEqual(state.undoEntries.map(\.group), [nil, nil])
    }

    func testAGroupedForwardIsAdmittedLikeAnyForward() {
        var state = OperationHistoryState()
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginGroupedForward(request, group))
        // Busy: neither a second forward nor an undo is admitted while one is pending.
        let second = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginGroupedForward(second, HistoryGroup(name: "Move 3 Items")))
        XCTAssertEqual(state.pending, .forward(request, name: group.name))
        XCTAssertTrue(OperationHistoryReducer.reduce(&state, .beginUndo(HistoryRequestID())).isEmpty)
        finish(request, &state, outcome: .succeeded)
        XCTAssertEqual(state.undoEntries.map(\.group), [group], "the refused second group left nothing behind")

        // A request is good once.
        OperationHistoryReducer.reduce(&state, .beginGroupedForward(request, group))
        XCTAssertNil(state.pending)
    }

    func testAGroupedEntryThatNeedsReconciliationBlocksLikeAnyOther() {
        var state = OperationHistoryState()
        groupedForward(group, &state)
        groupedForward(group, &state)
        // An undo that only partly worked stops the group there: the entry stays, and history waits for the person.
        undo(&state, outcome: .partial("One item was in use"))
        XCTAssertEqual(state.undoEntries.count, 2)
        XCTAssertEqual(state.undoAvailability, .reconciliationRequired)
        XCTAssertTrue(state.redoEntries.isEmpty)
        OperationHistoryReducer.reduce(&state, .acknowledgeReconciliation)
        XCTAssertEqual(state.undoEntries.map(\.group), [group])
        XCTAssertEqual(state.undoAvailability, .available("Organize “Downloads”"))

        // A failed undo leaves the entry where it was, still in its group.
        undo(&state, outcome: .failed("Disk disconnected"))
        XCTAssertEqual(state.undoEntries.map(\.group), [group])
        XCTAssertTrue(state.redoEntries.isEmpty)
    }
}
