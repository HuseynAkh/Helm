// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmOperations

final class HistoryResultMappingTests: XCTestCase {
    func testNoStepsIsNoChange() {
        let plan = OperationPlan(command: .trash(items: []), steps: [])
        let result = OperationResult(id: OperationID(), command: plan.command, outcomes: [])
        XCTAssertEqual(HistoryResultMapping.outcome(result, plan: plan), .noChange)
    }
    func testMissingOutcomesIsFailure() {
        let step = PlannedStep(kind: .trash, source: URL(fileURLWithPath: "/a"))
        let plan = OperationPlan(command: .trash(items: []), steps: [step])
        let result = OperationResult(id: OperationID(), command: plan.command, outcomes: [])
        guard case .failed = HistoryResultMapping.outcome(result, plan: plan) else { return XCTFail("Incomplete") }
    }
    func testPartialKnownMutationRequiresReconciliation() {
        let first = PlannedStep(kind: .trash), second = PlannedStep(kind: .trash)
        let plan = OperationPlan(command: .recovery, steps: [first, second])
        let result = OperationResult(id: OperationID(), command: .recovery, outcomes: [
            ItemOutcome(step: first, destination: nil, result: .success(nil)),
            ItemOutcome(step: second, destination: nil, result: .failure(.notAttempted))], error: .cancelled)
        guard case .partial = HistoryResultMapping.outcome(result, plan: plan) else { return XCTFail("Partial lost") }
    }
    func testGuaranteedCancellationIsFailureWithoutReconciliation() {
        let step = PlannedStep(kind: .trash)
        let plan = OperationPlan(command: .recovery, steps: [step])
        let result = OperationResult(id: OperationID(), command: .recovery, outcomes: [
            ItemOutcome(step: step, destination: nil, result: .failure(.cancelled), requiresReconciliation: false)], error: .cancelled)
        let mapped = HistoryResultMapping.outcome(result, plan: plan)
        guard case .failed = mapped else { return XCTFail("Expected failure") }
        XCTAssertFalse(mapped.needsReconciliation)
    }
    func testVerifyOnlyIsNoChange() {
        let step = PlannedStep(kind: .verifyCopy)
        let plan = OperationPlan(command: .recovery, steps: [step])
        let result = OperationResult(id: OperationID(), command: .recovery, outcomes: [
            ItemOutcome(step: step, destination: nil, result: .success(nil))])
        XCTAssertEqual(HistoryResultMapping.outcome(result, plan: plan), .noChange)
    }
    func testNamesPreserveLegacyAndDistinguishDuplicate() throws {
        let url = URL(fileURLWithPath: "/a")
        let name = try XCTUnwrap(ValidFileName("b"))
        let cases: [(Command, String)] = [(.copy(sources: [], destinationDirectory: url), "Copy"),
            (.move(sources: [], destinationDirectory: url), "Move"), (.trash(items: []), "Move to Trash"),
            (.duplicate(sources: []), "Duplicate"), (.batchRename([]), "Rename"),
            (.createFolder(parent: url, name: name), "New Folder"),
            (.createFile(parent: url, name: name, template: nil), "New File"), (.recovery, "Recovery")]
        for (command, expected) in cases { XCTAssertEqual(HistoryResultMapping.name(for: command), expected) }
    }
}
