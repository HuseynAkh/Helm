// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmOperations

final class HistoryAdmissionTests: XCTestCase {
    private func plan() throws -> OperationPlan {
        let url = URL(fileURLWithPath: "/target/new")
        return OperationPlan(command: .createFolder(parent: url.deletingLastPathComponent(), name: try XCTUnwrap(ValidFileName("new"))),
                             steps: [PlannedStep(kind: .createDirectory, destination: url)])
    }
    func testPreparationTerminationIsSingleUseAndRequestMatched() async throws {
        for failure: HistoryPreparationFailure in [.cancelled, .failed("planning denied")] {
            let history = WindowOperationHistory()
            let value = await history.beginForward(try plan().command)
            let request = try XCTUnwrap(value)
            let stale = await history.abortForward(request: HistoryRequestID(), failure: failure)
            XCTAssertFalse(stale)
            let accepted = await history.abortForward(request: request, failure: failure)
            XCTAssertTrue(accepted)
            let duplicate = await history.abortForward(request: request, failure: failure)
            XCTAssertFalse(duplicate)
            let state = await history.snapshot()
            XCTAssertNil(state.pending)
            XCTAssertEqual(state.lastOutcome, failure.outcome)
            XCTAssertTrue(state.undoEntries.isEmpty)
            let next = await history.beginForward(try plan().command)
            XCTAssertNotNil(next)
        }
    }
    func testBoundForwardCannotAbortAndRejectsForeignOrMalformedResults() async throws {
        let history = WindowOperationHistory(), plan = try plan(), id = OperationID()
        let value = await history.beginForward(plan.command)
        let request = try XCTUnwrap(value)
        let bound = await history.bindExecution(request: request, operation: id, plan: plan)
        XCTAssertTrue(bound)
        let abort = await history.abortForward(request: request, failure: .cancelled)
        XCTAssertFalse(abort)
        let foreign = OperationID()
        let rejected = await history.completeForward(request: request,
            entry: JournalEntry(id: foreign, plan: plan, result: OperationResult(id: foreign, command: plan.command, outcomes: [])))
        XCTAssertFalse(rejected)
        let malformed = await history.completeForward(request: request,
            entry: JournalEntry(id: id, plan: plan, result: OperationResult(id: id, command: plan.command, outcomes: [])))
        XCTAssertFalse(malformed)
        let result = OperationResult(id: id, command: plan.command,
            outcomes: plan.steps.map { ItemOutcome(step: $0, destination: $0.destination, result: .failure(.notAttempted)) },
            error: .busy)
        let accepted = await history.completeForward(request: request, entry: JournalEntry(id: id, plan: plan, result: result))
        XCTAssertTrue(accepted)
    }
    func testExecutorBusyIsBoundJournaledAndReleasesForward() async throws {
        let fs = InMemoryFileSystem()
        let executor = OperationExecutor(fileSystem: fs)
        let history = WindowOperationHistory(), plan = try plan()
        // Reenter while the outer execution is held at admission; no filesystem work yet.
        let outer = await executor.execute(plan, admission: { _ in
            let value = await history.beginForward(plan.command)
            guard let request = value else { XCTFail("Reservation refused"); return false }
            let result = await executor.execute(plan, admission: { id in
                await history.bindExecution(request: request, operation: id, plan: plan)
            })
            XCTAssertEqual(result.error, .busy)
            XCTAssertEqual(result.outcomes.map(\.step), plan.steps)
            let stored = await executor.journal.entry(result.id)
            if let stored {
                let accepted = await history.completeForward(request: request, entry: stored)
                XCTAssertTrue(accepted)
            } else { XCTFail("Busy refusal missing journal") }
            let state = await history.snapshot()
            XCTAssertNil(state.pending)
            XCTAssertTrue(state.undoEntries.isEmpty)
            return false
        })
        XCTAssertEqual(outer.error, .invalidPlan)
        let exists = await fs.exists(URL(fileURLWithPath: "/target/new"))
        XCTAssertFalse(exists)
        let next = await history.beginForward(plan.command)
        XCTAssertNotNil(next)
    }

    func testCancelledPlanningDoesNotEnterExecutor() async throws {
        let history = WindowOperationHistory(), plan = try plan()
        let fs = InMemoryFileSystem(), journal = OperationJournal()
        let executor = OperationExecutor(fileSystem: fs, journal: journal)
        let value = await history.beginForward(plan.command)
        let request = try XCTUnwrap(value)
        do {
            try cancelledPlanning()
            _ = await executor.execute(plan)
            XCTFail("Cancelled planning unexpectedly returned")
        } catch is CancellationError {
            let aborted = await history.abortForward(request: request, failure: .cancelled)
            XCTAssertTrue(aborted)
        }
        let entries = await journal.allEntries()
        XCTAssertTrue(entries.isEmpty)
        let exists = await fs.exists(URL(fileURLWithPath: "/target/new"))
        XCTAssertFalse(exists)
    }

    private func cancelledPlanning() throws { throw CancellationError() }

    func testStaleOrDuplicateBindingCannotReplaceExecution() async throws {
        let history = WindowOperationHistory(), plan = try plan(), id = OperationID()
        let value = await history.beginForward(plan.command)
        let request = try XCTUnwrap(value)
        let stale = await history.bindExecution(request: HistoryRequestID(), operation: id, plan: plan)
        XCTAssertFalse(stale)
        let first = await history.bindExecution(request: request, operation: id, plan: plan)
        XCTAssertTrue(first)
        let repeated = await history.bindExecution(request: request, operation: OperationID(), plan: plan)
        XCTAssertFalse(repeated)
        let state = await history.snapshot()
        XCTAssertEqual(state.executingOperation, id)
    }

    func testIndependentExecutedInverseCannotConsumeAnotherWindow() async throws {
        let fs = InMemoryFileSystem()
        let parent = URL(fileURLWithPath: "/target")
        try await fs.createDirectory(at: parent)
        let a = WindowOperationHistory(), b = WindowOperationHistory()
        let ea = OperationExecutor(fileSystem: fs), eb = OperationExecutor(fileSystem: fs)
        for (history, executor, name) in [(a, ea, "a"), (b, eb, "b")] {
            let command = Command.createFile(parent: parent, name: try XCTUnwrap(ValidFileName(name)), template: nil)
            let plan = OperationPlan(command: command,
                steps: [PlannedStep(kind: .createFile, destination: parent.appendingPathComponent(name))])
            let value = await history.beginForward(command)
            let request = try XCTUnwrap(value)
            let result = await executor.execute(plan, admission: { id in
                await history.bindExecution(request: request, operation: id, plan: plan)
            })
            XCTAssertNil(result.error)
            let stored = await executor.journal.entry(result.id)
            let entry = try XCTUnwrap(stored)
            let accepted = await history.completeForward(request: request, entry: entry)
            XCTAssertTrue(accepted)
        }
        let av = await a.beginUndo(), bv = await b.beginUndo()
        let ar = try XCTUnwrap(av), br = try XCTUnwrap(bv)
        let resultA = await ea.execute(ar.plan, admission: { id in
            let bound = await a.bindExecution(request: ar.request, operation: id, plan: ar.plan)
            XCTAssertTrue(bound)
            let resultB = await eb.execute(br.plan, admission: { bid in
                await b.bindExecution(request: br.request, operation: bid, plan: br.plan)
            })
            XCTAssertNil(resultB.error)
            let foreign = await a.complete(request: ar.request, outcome: resultB)
            XCTAssertFalse(foreign)
            let attempts = await a.inverseAttempts()
            XCTAssertTrue(attempts.isEmpty)
            let state = await a.snapshot()
            XCTAssertEqual(state.pending?.request, ar.request)
            let acceptedB = await b.complete(request: br.request, outcome: resultB)
            XCTAssertTrue(acceptedB)
            return bound
        })
        XCTAssertNil(resultA.error)
        let acceptedA = await a.complete(request: ar.request, outcome: resultA)
        XCTAssertTrue(acceptedA)
    }

}
