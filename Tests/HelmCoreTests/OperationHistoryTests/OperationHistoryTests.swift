// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import HelmCore

final class OperationHistoryTests: XCTestCase {
    private func populated() -> OperationHistoryState {
        var state = OperationHistoryState()
        append(&state)
        return state
    }
    private func append(_ state: inout OperationHistoryState, outcome: HistoryOutcome = .succeeded) {
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginForward(request, name: "Copy"))
        let operation = OperationID()
        OperationHistoryReducer.reduce(&state, .startForward(request, operation: operation))
        OperationHistoryReducer.reduce(&state, .finishForward(request, operation: operation, outcome: outcome))
    }
    func testEmptyAvailability() {
        let state = OperationHistoryState()
        XCTAssertEqual(state.undoAvailability, .empty)
        XCTAssertEqual(state.redoAvailability, .empty)
    }
    func testNamedForward() {
        XCTAssertEqual(populated().undoAvailability, .available("Copy"))
    }
    func testUndoReservesOriginal() {
        var state = populated()
        let request = HistoryRequestID()
        XCTAssertEqual(OperationHistoryReducer.reduce(&state, .beginUndo(request)),
                       [.performUndo(request, state.undoEntries[0].operationID)])
        XCTAssertEqual(state.undoAvailability, .busy)
        XCTAssertEqual(state.redoAvailability, .busy)
    }
    func testDoubleUndoIgnored() {
        var state = populated()
        OperationHistoryReducer.reduce(&state, .beginUndo(HistoryRequestID()))
        XCTAssertTrue(OperationHistoryReducer.reduce(&state, .beginUndo(HistoryRequestID())).isEmpty)
    }
    func testStaleUndoCompletionIgnored() {
        var state = populated()
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginUndo(request))
        OperationHistoryReducer.reduce(&state, .complete(HistoryRequestID(), outcome: .succeeded))
        XCTAssertEqual(state.pending?.request, request)
        XCTAssertTrue(state.redoEntries.isEmpty)
    }
    func testStaleForwardCompletionIgnored() {
        var state = OperationHistoryState()
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginForward(request, name: "Move"))
        OperationHistoryReducer.reduce(&state, .finishForward(HistoryRequestID(), operation: OperationID(), outcome: .succeeded))
        XCTAssertEqual(state.pending?.request, request)
        XCTAssertTrue(state.undoEntries.isEmpty)
    }
    func testSuccessMovesOnlyOriginalToRedo() {
        var state = populated()
        let original = state.undoEntries
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginUndo(request))
        OperationHistoryReducer.reduce(&state, .complete(request, outcome: .succeeded))
        XCTAssertTrue(state.undoEntries.isEmpty)
        XCTAssertEqual(state.redoEntries, original)
        XCTAssertEqual(state.redoAvailability, .unsupported("Copy"))
    }
    func testDuplicateCompletionIgnored() {
        var state = populated()
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginUndo(request))
        OperationHistoryReducer.reduce(&state, .complete(request, outcome: .succeeded))
        OperationHistoryReducer.reduce(&state, .complete(request, outcome: .failed("late")))
        XCTAssertEqual(state.lastOutcome, .succeeded)
        XCTAssertEqual(state.redoEntries.count, 1)
    }
    func testReusedRequestRejected() {
        var state = populated()
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginUndo(request))
        OperationHistoryReducer.reduce(&state, .complete(request, outcome: .refused("leaf")))
        XCTAssertTrue(OperationHistoryReducer.reduce(&state, .beginUndo(request)).isEmpty)
        XCTAssertNil(state.pending)
    }
    func testRefusalRetainsUndo() {
        var state = populated()
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginUndo(request))
        OperationHistoryReducer.reduce(&state, .complete(request, outcome: .refused("leaf")))
        XCTAssertEqual(state.undoEntries.count, 1)
        XCTAssertEqual(state.lastOutcome, .refused("leaf"))
    }
    func testFailedUndoRetainsUndo() {
        var state = populated()
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginUndo(request))
        OperationHistoryReducer.reduce(&state, .complete(request, outcome: .failed("denied")))
        XCTAssertEqual(state.undoAvailability, .available("Copy"))
    }
    func testPartialUndoBlocksHistory() {
        var state = populated()
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginUndo(request))
        OperationHistoryReducer.reduce(&state, .complete(request, outcome: .partial("one moved")))
        XCTAssertEqual(state.undoAvailability, .reconciliationRequired)
        XCTAssertEqual(state.redoAvailability, .reconciliationRequired)
        append(&state)
        XCTAssertEqual(state.undoEntries.count, 1)
    }
    func testUncertainForwardRetained() {
        var state = OperationHistoryState()
        append(&state, outcome: .reconciliationRequired("timeout"))
        XCTAssertEqual(state.undoEntries.count, 1)
        XCTAssertEqual(state.reconciliation, .reconciliationRequired("timeout"))
    }
    func testNoChangeForwardNotRegistered() {
        var state = OperationHistoryState()
        append(&state, outcome: .noChange)
        XCTAssertTrue(state.undoEntries.isEmpty)
    }
    func testFailedForwardNotRegistered() {
        var state = OperationHistoryState()
        append(&state, outcome: .failed("denied"))
        XCTAssertTrue(state.undoEntries.isEmpty)
        XCTAssertEqual(state.lastOutcome, .failed("denied"))
    }
    func testNewForwardClearsRedoBeforeCompletion() {
        var state = populated()
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginUndo(request))
        OperationHistoryReducer.reduce(&state, .complete(request, outcome: .succeeded))
        OperationHistoryReducer.reduce(&state, .beginForward(HistoryRequestID(), name: "Rename"))
        XCTAssertTrue(state.redoEntries.isEmpty)
    }
    func testForwardCannotInterleaveUndo() {
        var state = populated()
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginUndo(request))
        OperationHistoryReducer.reduce(&state, .beginForward(HistoryRequestID(), name: "Move"))
        XCTAssertEqual(state.pending?.request, request)
    }
    func testRedoNeverEmitsMutation() {
        var state = populated()
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginUndo(request))
        OperationHistoryReducer.reduce(&state, .complete(request, outcome: .succeeded))
        XCTAssertTrue(OperationHistoryReducer.reduce(&state, .beginRedo).isEmpty)
        guard case .unsupported = state.lastOutcome else { return XCTFail("Expected unsupported") }
        XCTAssertNil(state.pending)
    }
    func testEmptyUndoDoesNotReserve() {
        var state = OperationHistoryState()
        XCTAssertTrue(OperationHistoryReducer.reduce(&state, .beginUndo(HistoryRequestID())).isEmpty)
        XCTAssertNil(state.pending)
    }
    func testUndoIsLIFO() {
        var state = populated()
        append(&state)
        let last = state.undoEntries.last
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginUndo(request))
        OperationHistoryReducer.reduce(&state, .complete(request, outcome: .succeeded))
        XCTAssertEqual(state.redoEntries.last, last)
        XCTAssertEqual(state.undoEntries.count, 1)
    }
    func testPreparationAbortCannotReleaseExecutingForward() {
        var state = OperationHistoryState()
        let request = HistoryRequestID(), operation = OperationID()
        OperationHistoryReducer.reduce(&state, .beginForward(request, name: "Copy"))
        OperationHistoryReducer.reduce(&state, .startForward(HistoryRequestID(), operation: operation))
        XCTAssertNil(state.executingOperation)
        OperationHistoryReducer.reduce(&state, .startForward(request, operation: operation))
        OperationHistoryReducer.reduce(&state, .startForward(request, operation: OperationID()))
        XCTAssertEqual(state.executingOperation, operation)
        OperationHistoryReducer.reduce(&state, .abortForward(request, failure: .cancelled))
        XCTAssertEqual(state.pending?.request, request)
        OperationHistoryReducer.reduce(&state, .finishForward(request, operation: OperationID(), outcome: .succeeded))
        XCTAssertEqual(state.pending?.request, request)
        OperationHistoryReducer.reduce(&state, .finishForward(request, operation: operation, outcome: .failed("cancelled")))
        XCTAssertNil(state.pending)
        XCTAssertNil(state.executingOperation)
    }

    func testPreparationAbortPreservesRedoInvalidationAndRejectsStaleRequests() {
        var state = populated()
        let undo = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginUndo(undo))
        OperationHistoryReducer.reduce(&state, .complete(undo, outcome: .succeeded))
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginForward(request, name: "Copy"))
        OperationHistoryReducer.reduce(&state, .abortForward(HistoryRequestID(), failure: .cancelled))
        XCTAssertEqual(state.pending?.request, request)
        OperationHistoryReducer.reduce(&state, .abortForward(request, failure: .failed("planning")))
        XCTAssertNil(state.pending)
        XCTAssertTrue(state.redoEntries.isEmpty)
        OperationHistoryReducer.reduce(&state, .abortForward(request, failure: .cancelled))
        XCTAssertEqual(state.lastOutcome, .failed("planning"))
        OperationHistoryReducer.reduce(&state, .beginForward(request, name: "Copy"))
        XCTAssertNil(state.pending)
    }

}
