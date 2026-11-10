// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import HelmCore

final class F23UndoPreparationTests: XCTestCase {
    private func populated() -> OperationHistoryState {
        var state = OperationHistoryState()
        for name in ["First", "Second"] {
            let request = HistoryRequestID(), operation = OperationID()
            OperationHistoryReducer.reduce(&state, .beginForward(request, name: name))
            OperationHistoryReducer.reduce(&state, .startForward(request, operation: operation))
            OperationHistoryReducer.reduce(&state, .finishForward(request, operation: operation, outcome: .succeeded))
        }
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginUndo(request))
        OperationHistoryReducer.reduce(&state, .complete(request, outcome: .succeeded))
        return state
    }

    func testPreparationAbortPreservesNonemptyUndoAndRedoStacks() {
        var state = populated()
        let undo = state.undoEntries, redo = state.redoEntries
        XCTAssertEqual(undo.count, 1)
        XCTAssertEqual(redo.count, 1)
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginUndo(request))
        OperationHistoryReducer.reduce(&state, .abortUndo(HistoryRequestID(), failure: .cancelled))
        XCTAssertEqual(state.pending?.request, request)
        OperationHistoryReducer.reduce(&state, .abortUndo(request, failure: .cancelled))
        XCTAssertNil(state.pending)
        XCTAssertEqual(state.undoEntries, undo)
        XCTAssertEqual(state.redoEntries, redo)
        XCTAssertEqual(state.lastOutcome, HistoryPreparationFailure.cancelled.outcome)
        OperationHistoryReducer.reduce(&state, .abortUndo(request, failure: .failed("duplicate")))
        XCTAssertEqual(state.lastOutcome, HistoryPreparationFailure.cancelled.outcome)
        OperationHistoryReducer.reduce(&state, .beginUndo(request))
        XCTAssertNil(state.pending)
        let next = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginUndo(next))
        XCTAssertEqual(state.pending?.request, next)
    }

    func testStartUndoRejectsStaleDuplicateAndAbortAfterBinding() {
        var state = populated()
        let request = HistoryRequestID(), operation = OperationID()
        OperationHistoryReducer.reduce(&state, .beginUndo(request))
        OperationHistoryReducer.reduce(&state, .startUndo(HistoryRequestID(), operation: operation))
        XCTAssertNil(state.executingOperation)
        OperationHistoryReducer.reduce(&state, .startUndo(request, operation: operation))
        OperationHistoryReducer.reduce(&state, .startUndo(request, operation: OperationID()))
        XCTAssertEqual(state.executingOperation, operation)
        OperationHistoryReducer.reduce(&state, .abortUndo(request, failure: .cancelled))
        XCTAssertEqual(state.pending?.request, request)
        OperationHistoryReducer.reduce(&state, .complete(request, outcome: .failed("execution failed")))
        XCTAssertNil(state.executingOperation)
        XCTAssertNil(state.pending)
        XCTAssertEqual(state.undoEntries.count, 1)
        XCTAssertEqual(state.redoEntries.count, 1)
    }

    func testUndoPreparationActionsCannotAlterForwardReservation() {
        var state = OperationHistoryState()
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginForward(request, name: "Copy"))
        OperationHistoryReducer.reduce(&state, .startUndo(request, operation: OperationID()))
        OperationHistoryReducer.reduce(&state, .abortUndo(request, failure: .cancelled))
        XCTAssertEqual(state.pending, .forward(request, name: "Copy"))
        XCTAssertNil(state.executingOperation)
        XCTAssertNil(state.lastOutcome)
    }
}
