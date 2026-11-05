// DRAFT: pending review, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmOperations

final class HistoryReconciliationTests: XCTestCase {
    private func record(_ entry: JournalEntry, in history: WindowOperationHistory) async throws {
        let reservation = await history.beginForward(entry.plan.command)
        let request = try XCTUnwrap(reservation)
        let bound = await history.bindExecution(request: request, operation: entry.id, plan: entry.plan)
        XCTAssertTrue(bound)
        let accepted = await history.completeForward(request: request, entry: entry)
        XCTAssertTrue(accepted)
    }

    func testKnownForwardPrefixCanActuallyBeUndoneAfterCancellationOrFailure() async throws {
        for error: OperationError in [.cancelled, .verificationUnavailable] {
            let fs = InMemoryFileSystem()
            let target = URL(fileURLWithPath: "/target")
            try await fs.createDirectory(at: target)
            let destination = target.appendingPathComponent("first")
            try await fs.createFileExclusively(at: destination, contents: Data([1]))
            let evidence = try await fs.mutationPrecondition(at: destination)
            let steps = (0..<3).map { index in
                PlannedStep(kind: .copy, source: URL(fileURLWithPath: "/source/\(index)"),
                            destination: index == 0 ? destination : target.appendingPathComponent("\(index)"))
            }
            let command = Command.copy(sources: steps.compactMap(\.source), destinationDirectory: target)
            let plan = OperationPlan(command: command, steps: steps)
            let operation = OperationID()
            let outcomes = [ItemOutcome(step: steps[0], destination: destination,
                result: .success(evidence.changeToken), destinationKind: .regular, destinationEvidence: evidence)]
                + steps.dropFirst().map { ItemOutcome(step: $0, destination: $0.destination,
                    result: .failure(.notAttempted), requiresReconciliation: false) }
            let result = OperationResult(id: operation, command: command, outcomes: outcomes, error: error)
            guard case .partial = HistoryResultMapping.outcome(result, plan: plan) else {
                return XCTFail("Known prefix must map to partial")
            }
            let history = WindowOperationHistory()
            try await record(JournalEntry(id: operation, plan: plan, result: result), in: history)
            let state = await history.snapshot()
            XCTAssertNil(state.reconciliation)
            let reservation = await history.beginUndo()
            let undo = try XCTUnwrap(reservation)
            XCTAssertTrue(undo.plan.isExecutable)
            XCTAssertEqual(undo.plan.steps.count, 1)
            XCTAssertEqual(undo.plan.steps.first?.source, destination)
            let executor = OperationExecutor(fileSystem: fs)
            let undone = await executor.execute(undo.plan, admission: { operation in
                await history.bindExecution(request: undo.request, operation: operation, plan: undo.plan)
            })
            let completed = await history.complete(request: undo.request, outcome: undone)
            XCTAssertTrue(completed)
            XCTAssertNil(undone.error)
            XCTAssertTrue(undone.outcomes.allSatisfy(\.succeeded))
            let exists = await fs.exists(destination)
            XCTAssertFalse(exists)
        }
    }

    func testUncertainForwardBlocksUntilAcknowledgedAndRetainsEvidence() async throws {
        let history = WindowOperationHistory()
        let source = URL(fileURLWithPath: "/source/item")
        let hidden = URL(fileURLWithPath: "/target/.helm-stage-item")
        let command = Command.copy(sources: [source], destinationDirectory: hidden.deletingLastPathComponent())
        let step = PlannedStep(kind: .copy, source: source, destination: hidden)
        let earlier = PlannedStep(kind: .copy, source: source,
                                  destination: URL(fileURLWithPath: "/target/earlier"))
        let plan = OperationPlan(command: command, steps: [earlier, step])
        let id = OperationID()
        let result = OperationResult(id: id, command: command, outcomes: [
            ItemOutcome(step: earlier, destination: earlier.destination, result: .success(nil)),
            ItemOutcome(step: step, destination: hidden, result: .failure(.timedOut),
                        requiresReconciliation: true)], error: .timedOut)
        guard case .reconciliationRequired = HistoryResultMapping.outcome(result, plan: plan) else {
            return XCTFail("Uncertainty must win over partial work")
        }
        let entry = JournalEntry(id: id, plan: plan, result: result)
        try await record(entry, in: history)
        let undo = await history.beginUndo()
        let forward = await history.beginForward(command)
        XCTAssertNil(undo)
        XCTAssertNil(forward)
        let acknowledged = await history.acknowledgeReconciliation()
        XCTAssertTrue(acknowledged)
        let state = await history.snapshot()
        XCTAssertNil(state.reconciliation)
        XCTAssertTrue(state.undoEntries.isEmpty)
        XCTAssertTrue(state.redoEntries.isEmpty)
        let retained = await history.entry(for: id)
        XCTAssertEqual(retained?.result?.outcomes.last?.destination, hidden)
        XCTAssertEqual(retained?.result?.error, .timedOut)
        let repeated = await history.acknowledgeReconciliation()
        XCTAssertFalse(repeated)
        let next = await history.beginForward(command)
        XCTAssertNotNil(next)
        let busyAcknowledgement = await history.acknowledgeReconciliation()
        XCTAssertFalse(busyAcknowledgement)
        let busy = await history.snapshot()
        XCTAssertEqual(busy.pending?.request, next)
    }

    func testAcknowledgementWithoutReconciliationRefuses() async {
        let history = WindowOperationHistory()
        let acknowledged = await history.acknowledgeReconciliation()
        XCTAssertFalse(acknowledged)
    }
}
