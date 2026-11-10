import XCTest
import HelmCore

/// A change the history can't undo, such as a new archive, ends what Undo and Redo can reach: Cmd+Z right after it
/// must not quietly undo an older change instead.
final class HuntOperationsHistoryTests: XCTestCase {
    private func finish(_ name: String, _ state: inout OperationHistoryState) -> OperationID {
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginForward(request, name: name))
        let operation = OperationID()
        OperationHistoryReducer.reduce(&state, .startForward(request, operation: operation))
        OperationHistoryReducer.reduce(&state, .finishForward(request, operation: operation, outcome: .succeeded))
        return operation
    }

    func testAChangeThatCantBeUndoneEndsWhatUndoCanReach() {
        var state = OperationHistoryState()
        _ = finish("Rename", &state)
        _ = finish("Copy", &state)
        let undo = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginUndo(undo))
        OperationHistoryReducer.reduce(&state, .startUndo(undo, operation: OperationID()))
        OperationHistoryReducer.reduce(&state, .complete(undo, outcome: .succeeded))
        XCTAssertEqual(state.undoAvailability, .available("Rename"))
        XCTAssertEqual(state.redoAvailability, .unsupported("Copy"))

        OperationHistoryReducer.reduce(&state, .discardEntries)
        XCTAssertEqual(state.undoAvailability, .empty, "Undo doesn't reach back past the archive to the rename")
        XCTAssertEqual(state.redoAvailability, .empty)

        _ = finish("Duplicate", &state)
        XCTAssertEqual(state.undoAvailability, .available("Duplicate"), "later changes are recorded as usual")
    }

    /// A running undo owns the top entry until it completes, so the entries stay until it's done.
    func testEntriesStayWhileAnUndoIsRunning() {
        var state = OperationHistoryState()
        _ = finish("Rename", &state)
        let undo = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginUndo(undo))
        OperationHistoryReducer.reduce(&state, .discardEntries)
        XCTAssertEqual(state.undoEntries.map(\.name), ["Rename"])
        OperationHistoryReducer.reduce(&state, .startUndo(undo, operation: OperationID()))
        OperationHistoryReducer.reduce(&state, .complete(undo, outcome: .succeeded))
        XCTAssertEqual(state.redoAvailability, .unsupported("Rename"))
    }
}
