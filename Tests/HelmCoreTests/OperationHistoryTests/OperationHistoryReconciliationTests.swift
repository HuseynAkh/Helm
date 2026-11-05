// DRAFT: pending review, 2026-11-04
import XCTest
import HelmCore

final class OperationHistoryReconciliationTests: XCTestCase {
    @discardableResult
    private func append(_ state: inout OperationHistoryState, outcome: HistoryOutcome) -> HistoryEntry {
        let request = HistoryRequestID(), operation = OperationID()
        OperationHistoryReducer.reduce(&state, .beginForward(request, name: "Copy"))
        OperationHistoryReducer.reduce(&state, .startForward(request, operation: operation))
        OperationHistoryReducer.reduce(&state, .finishForward(request, operation: operation, outcome: outcome))
        return HistoryEntry(operationID: operation, name: "Copy")
    }

    func testAcknowledgementRemovesOnlyBlockedTopAndCannotRepeat() {
        var state = OperationHistoryState()
        let older = append(&state, outcome: .succeeded)
        append(&state, outcome: .reconciliationRequired("uncertain"))
        XCTAssertTrue(OperationHistoryReducer.reduce(&state, .acknowledgeReconciliation).isEmpty)
        XCTAssertNil(state.reconciliation)
        XCTAssertEqual(state.undoEntries, [older])
        XCTAssertTrue(state.redoEntries.isEmpty)
        XCTAssertEqual(state.lastOutcome, .reconciliationRequired("uncertain"))
        OperationHistoryReducer.reduce(&state, .acknowledgeReconciliation)
        XCTAssertEqual(state.undoEntries, [older])
        XCTAssertEqual(state.undoAvailability, .available("Copy"))
    }

    func testPartialInverseStillLatchesAndAcknowledgementNeverReplaysIt() {
        var state = OperationHistoryState()
        let older = append(&state, outcome: .succeeded)
        append(&state, outcome: .succeeded)
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginUndo(request))
        OperationHistoryReducer.reduce(&state, .complete(request, outcome: .partial("one moved")))
        XCTAssertEqual(state.undoAvailability, .reconciliationRequired)
        XCTAssertTrue(OperationHistoryReducer.reduce(&state, .beginUndo(HistoryRequestID())).isEmpty)
        OperationHistoryReducer.reduce(&state, .acknowledgeReconciliation)
        XCTAssertEqual(state.undoEntries, [older])
        XCTAssertTrue(state.redoEntries.isEmpty)
        XCTAssertNil(state.reconciliation)
    }

    func testAcknowledgementWithoutLatchPreservesPendingAndStacks() {
        var state = OperationHistoryState()
        OperationHistoryReducer.reduce(&state, .acknowledgeReconciliation)
        XCTAssertTrue(state.undoEntries.isEmpty)
        let original = append(&state, outcome: .succeeded)
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginUndo(request))
        OperationHistoryReducer.reduce(&state, .acknowledgeReconciliation)
        XCTAssertEqual(state.pending?.request, request)
        XCTAssertEqual(state.undoEntries, [original])
        OperationHistoryReducer.reduce(&state, .complete(request, outcome: .succeeded))
        OperationHistoryReducer.reduce(&state, .acknowledgeReconciliation)
        XCTAssertEqual(state.redoEntries, [original])
    }

    func testForwardPartialAllowsNewForwardWithoutAcknowledgement() {
        var state = OperationHistoryState()
        let partial = append(&state, outcome: .partial("cancelled"))
        XCTAssertNil(state.reconciliation)
        let request = HistoryRequestID()
        OperationHistoryReducer.reduce(&state, .beginForward(request, name: "Move"))
        XCTAssertEqual(state.pending?.request, request)
        XCTAssertEqual(state.undoEntries, [partial])
    }
}
