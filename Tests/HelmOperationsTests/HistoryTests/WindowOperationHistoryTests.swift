// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmOperations

final class WindowOperationHistoryTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/source/item")
    private let target = URL(fileURLWithPath: "/target/item")
    private func fixture(token: Bool = true, kind: FileEntryKind = .regular) -> JournalEntry {
        let command = Command.copy(sources: [source], destinationDirectory: target.deletingLastPathComponent())
        let step = PlannedStep(kind: .copy, source: source, destination: target)
        let plan = OperationPlan(command: command, steps: [step])
        let id = OperationID()
        let change = ChangeToken(modificationDate: Date(timeIntervalSince1970: 1), size: 4)
        let evidence = FileMutationPrecondition(identity: FileObjectIdentity(scope: "test", object: "1"), changeToken: change, kind: kind)
        let item = ItemOutcome(step: step, destination: target, result: .success(token ? change : nil),
                               destinationKind: kind, destinationEvidence: evidence)
        return JournalEntry(id: id, plan: plan, result: OperationResult(id: id, command: command, outcomes: [item]))
    }
    private func seeded(_ entry: JournalEntry? = nil) async throws -> WindowOperationHistory {
        let history = WindowOperationHistory()
        let value = entry ?? fixture()
        let request = await history.beginForward(value.plan.command)
        let id = try XCTUnwrap(request)
        let bound = await history.bindExecution(request: id, operation: value.id, plan: value.plan)
        XCTAssertTrue(bound)
        let accepted = await history.completeForward(request: id, entry: value)
        XCTAssertTrue(accepted)
        return history
    }
    private func success(_ request: HistoryUndoRequest, history: WindowOperationHistory) async -> OperationResult {
        let id = OperationID()
        let bound = await history.bindExecution(request: request.request, operation: id, plan: request.plan)
        XCTAssertTrue(bound)
        return OperationResult(id: id, command: .recovery, outcomes: request.plan.steps.map {
            ItemOutcome(step: $0, destination: $0.destination, result: .success(nil))
        })
    }
    func testIndependentWindows() async throws {
        let first = try await seeded()
        let second = WindowOperationHistory()
        let a = await first.snapshot(), b = await second.snapshot()
        XCTAssertEqual(a.undoAvailability, .available("Copy"))
        XCTAssertEqual(b.undoAvailability, .empty)
    }
    func testConcurrentUndoAdmitsOne() async throws {
        let history = try await seeded()
        let count = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<20 { group.addTask { await history.beginUndo() != nil } }
            var total = 0
            for await admitted in group where admitted { total += 1 }
            return total
        }
        XCTAssertEqual(count, 1)
    }
    func testInverseIsNotForwardHistory() async throws {
        let history = try await seeded()
        let value = await history.beginUndo()
        let request = try XCTUnwrap(value)
        let accepted = await history.complete(request: request.request, outcome: await success(request, history: history))
        XCTAssertTrue(accepted)
        let state = await history.snapshot()
        XCTAssertTrue(state.undoEntries.isEmpty)
        XCTAssertEqual(state.redoEntries.count, 1)
        let attempts = await history.inverseAttempts()
        XCTAssertEqual(attempts.count, 1)
        let recovery = await history.beginForward(.recovery)
        XCTAssertNil(recovery)
    }
    func testStaleCompletionDoesNotReleaseBusy() async throws {
        let history = try await seeded()
        let value = await history.beginUndo()
        let request = try XCTUnwrap(value)
        let accepted = await history.complete(request: HistoryRequestID(), outcome: await success(request, history: history))
        XCTAssertFalse(accepted)
        let state = await history.snapshot()
        XCTAssertEqual(state.undoAvailability, .busy)
    }
    func testDuplicateCompletionRejected() async throws {
        let history = try await seeded()
        let value = await history.beginUndo()
        let request = try XCTUnwrap(value)
        let result = await success(request, history: history)
        let first = await history.complete(request: request.request, outcome: result)
        let duplicate = await history.complete(request: request.request, outcome: result)
        XCTAssertTrue(first)
        XCTAssertFalse(duplicate)
    }
    func testForwardBlockedDuringUndo() async throws {
        let history = try await seeded()
        _ = await history.beginUndo()
        let request = await history.beginForward(fixture().plan.command)
        XCTAssertNil(request)
    }
    func testUndoBlockedDuringForward() async throws {
        let history = try await seeded()
        _ = await history.beginForward(fixture().plan.command)
        let request = await history.beginUndo()
        XCTAssertNil(request)
    }
    func testMissingTokenRefusesPlanning() async throws {
        let history = try await seeded(fixture(token: false))
        let request = await history.beginUndo()
        XCTAssertNil(request)
        let state = await history.snapshot()
        guard case .refused = state.lastOutcome else { return XCTFail("Expected refusal") }
        XCTAssertEqual(state.undoEntries.count, 1)
    }
    func testLeafPolicyAndEvidencePreserved() async throws {
        let history = try await seeded(fixture(kind: .directory))
        let value = await history.beginUndo()
        let request = try XCTUnwrap(value)
        XCTAssertEqual(request.plan.undoVerification, .leafOnly)
        XCTAssertEqual(request.plan.expectedKinds[target], .directory)
        XCTAssertNotNil(request.plan.expectedEvidence[target])
        let result = OperationResult(id: OperationID(), command: .recovery,
            outcomes: request.plan.steps.map { ItemOutcome(step: $0, destination: nil,
                result: .failure(.notAttempted)) }, error: .verificationUnavailable)
        let bound = await history.bindExecution(request: request.request, operation: result.id, plan: request.plan)
        XCTAssertTrue(bound)
        let accepted = await history.complete(request: request.request, outcome: result)
        XCTAssertTrue(accepted)
        let state = await history.snapshot()
        guard case .refused = state.lastOutcome else { return XCTFail("Leaf refusal lost") }
        XCTAssertEqual(state.undoEntries.count, 1)
        XCTAssertTrue(state.redoEntries.isEmpty)
    }
    func testUncertainAttemptRetainedAndBlocksHistory() async throws {
        let history = try await seeded()
        let value = await history.beginUndo()
        let request = try XCTUnwrap(value)
        let step = try XCTUnwrap(request.plan.steps.first)
        let result = OperationResult(id: OperationID(), command: .recovery,
            outcomes: [ItemOutcome(step: step, destination: nil, result: .failure(.timedOut))], error: .timedOut)
        let bound = await history.bindExecution(request: request.request, operation: result.id, plan: request.plan)
        XCTAssertTrue(bound)
        _ = await history.complete(request: request.request, outcome: result)
        let state = await history.snapshot()
        XCTAssertEqual(state.undoAvailability, .reconciliationRequired)
        let attempts = await history.inverseAttempts()
        XCTAssertEqual(attempts.first?.result?.error, .timedOut)
        let original = await history.entry(for: request.originalOperation)
        XCTAssertNotNil(original)
        let next = await history.beginUndo()
        XCTAssertNil(next)
    }
    func testRedoExplicitlyUnsupported() async throws {
        let history = try await seeded()
        let value = await history.beginUndo()
        let request = try XCTUnwrap(value)
        _ = await history.complete(request: request.request, outcome: await success(request, history: history))
        let redo = await history.beginRedo()
        XCTAssertEqual(redo, .unsupported("Copy"))
        let state = await history.snapshot()
        XCTAssertNil(state.pending)
    }
    func testNewForwardClearsRedo() async throws {
        let history = try await seeded()
        let value = await history.beginUndo()
        let request = try XCTUnwrap(value)
        _ = await history.complete(request: request.request, outcome: await success(request, history: history))
        _ = await history.beginForward(fixture().plan.command)
        let state = await history.snapshot()
        XCTAssertTrue(state.redoEntries.isEmpty)
    }
    func testMismatchedJournalIdentityRejected() async throws {
        let history = WindowOperationHistory()
        let entry = fixture()
        let value = await history.beginForward(entry.plan.command)
        let request = try XCTUnwrap(value)
        let bound = await history.bindExecution(request: request, operation: entry.id, plan: entry.plan)
        XCTAssertTrue(bound)
        let wrong = JournalEntry(id: OperationID(), plan: entry.plan, result: entry.result)
        let accepted = await history.completeForward(request: request, entry: wrong)
        XCTAssertFalse(accepted)
        let valid = await history.completeForward(request: request, entry: entry)
        XCTAssertTrue(valid)
    }
    func testDuplicateForwardEntryRejected() async throws {
        let entry = fixture()
        let history = try await seeded(entry)
        let value = await history.beginForward(entry.plan.command)
        let request = try XCTUnwrap(value)
        let binding = await history.bindExecution(request: request, operation: entry.id, plan: entry.plan)
        XCTAssertFalse(binding)
        let accepted = await history.completeForward(request: request, entry: entry)
        XCTAssertFalse(accepted)
    }
    func testRecoveryResultCannotCompleteForward() async throws {
        let history = WindowOperationHistory()
        let entry = fixture()
        let value = await history.beginForward(entry.plan.command)
        let request = try XCTUnwrap(value)
        let bound = await history.bindExecution(request: request, operation: entry.id, plan: entry.plan)
        XCTAssertTrue(bound)
        let wrong = JournalEntry(id: entry.id, plan: entry.plan,
            result: OperationResult(id: entry.id, command: .recovery, outcomes: []))
        let accepted = await history.completeForward(request: request, entry: wrong)
        XCTAssertFalse(accepted)
    }
    func testEmptyRedoAndUndo() async {
        let history = WindowOperationHistory()
        let undo = await history.beginUndo()
        let redo = await history.beginRedo()
        XCTAssertNil(undo)
        XCTAssertEqual(redo, .empty)
    }
    func testForeignInverseDoesNotConsumeReservation() async throws {
        let history = try await seeded()
        let value = await history.beginUndo()
        let request = try XCTUnwrap(value)
        let genuine = await success(request, history: history)
        let foreignStep = PlannedStep(kind: .trash, source: target)
        let foreign = OperationResult(id: OperationID(), command: .recovery,
            outcomes: [ItemOutcome(step: foreignStep, destination: nil, result: .success(nil))])
        let accepted = await history.complete(request: request.request, outcome: foreign)
        XCTAssertFalse(accepted)
        let state = await history.snapshot()
        XCTAssertEqual(state.pending?.request, request.request)
        let attempts = await history.inverseAttempts()
        XCTAssertTrue(attempts.isEmpty)
        for error: OperationError? in [nil, .cancelled] {
            let unrelated = OperationResult(id: genuine.id, command: .recovery,
                outcomes: [ItemOutcome(step: foreignStep, destination: nil,
                    result: error.map { .failure($0) } ?? .success(nil))], error: error)
            let rejected = await history.complete(request: request.request, outcome: unrelated)
            XCTAssertFalse(rejected)
        }
        let empty = await history.complete(request: request.request,
            outcome: OperationResult(id: genuine.id, command: .recovery, outcomes: [], error: .busy))
        XCTAssertFalse(empty)
        let completed = await history.complete(request: request.request, outcome: genuine)
        XCTAssertTrue(completed)
    }

}
