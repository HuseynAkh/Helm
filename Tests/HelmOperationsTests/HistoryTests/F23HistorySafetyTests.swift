// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmOperations

final class F23HistorySafetyTests: XCTestCase {
    private let target = URL(fileURLWithPath: "/target/new")

    private func seeded() async throws -> (WindowOperationHistory, OperationExecutor, InMemoryFileSystem) {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: target.deletingLastPathComponent())
        let history = WindowOperationHistory()
        let executor = OperationExecutor(fileSystem: fs, origins: InMemoryTrashOrigins())
        let command = Command.createFile(parent: target.deletingLastPathComponent(),
            name: try XCTUnwrap(ValidFileName("new")), template: nil)
        let plan = OperationPlan(command: command, steps: [PlannedStep(kind: .createFile, destination: target)])
        let value = await history.beginForward(command)
        let request = try XCTUnwrap(value)
        let result = await executor.execute(plan, admission: { id, executingPlan in
            await history.bindExecution(request: request, operation: id, plan: executingPlan)
        })
        XCTAssertNil(result.error)
        let stored = await executor.journal.entry(result.id)
        let accepted = await history.completeForward(request: request, entry: try XCTUnwrap(stored))
        XCTAssertTrue(accepted)
        return (history, executor, fs)
    }

    private func altered(_ plan: OperationPlan, field: Int) -> OperationPlan {
        let token = ChangeToken(modificationDate: .distantPast, size: 1)
        let contexts = [
            PlanningContext(sourceManifest: [SourceEntry(source: target, relativePath: "", kind: .regular, size: 1, changeToken: token)]),
            PlanningContext(availableBytes: [target: 1]),
            PlanningContext(caseSensitive: [target: true]),
            PlanningContext(existingNames: [target: ["occupied"]]),
            PlanningContext(volumeIDs: [target: "other"]),
            PlanningContext(defaultPolicy: ConflictPolicy(defaultResolution: .replace)),
            PlanningContext(existingEntries: [target: FileEntry(url: target)])
        ]
        return OperationPlan(command: plan.command, steps: plan.steps,
            issues: field == 4 ? [.sameParentMove(target)] : plan.issues,
            context: field >= 5 ? contexts[field - 5] : plan.context,
            expectedTokens: field == 1 ? [:] : plan.expectedTokens,
            undoVerification: field == 0 ? .none : plan.undoVerification,
            expectedKinds: field == 2 ? [:] : plan.expectedKinds,
            expectedEvidence: field == 3 ? [:] : plan.expectedEvidence)
    }

    func testEveryInverseSafetyFieldMustMatchBeforeBinding() async throws {
        for field in 0..<12 {
            let (history, executor, fs) = try await seeded()
            let value = await history.beginUndo(recordedOrigins: [:])
            let undo = try XCTUnwrap(value)
            let accepted = await history.bindExecution(request: undo.request, operation: OperationID(),
                plan: altered(undo.plan, field: field))
            XCTAssertFalse(accepted, "Changed field \(field)")
            let pending = await history.snapshot()
            let attempts = await history.inverseAttempts()
            XCTAssertEqual(pending.pending?.request, undo.request)
            XCTAssertTrue(attempts.isEmpty)
            let original = try await fs.entry(at: target)
            XCTAssertEqual(original.objectIdentity, undo.plan.expectedEvidence[target]?.identity)
            // A rejected binding must not consume admission; the genuine plan still settles.
            if !accepted {
                let result = await executor.execute(undo.plan, admission: { id, executingPlan in
                    await history.bindExecution(request: undo.request, operation: id, plan: executingPlan)
                })
                let completed = await history.complete(request: undo.request, outcome: result)
                XCTAssertTrue(completed)
                XCTAssertNil(result.error)
            }
        }
    }

    func testReconstructedPlanCannotTrashReplacementOccupant() async throws {
        let (history, executor, fs) = try await seeded()
        let value = await history.beginUndo(recordedOrigins: [:])
        let undo = try XCTUnwrap(value)
        _ = try await fs.trashItem(at: target)
        try await fs.createFileExclusively(at: target, contents: Data("replacement".utf8))
        let replacement = try await fs.entry(at: target)
        let weakened = OperationPlan(command: undo.plan.command, steps: undo.plan.steps)
        let result = await executor.execute(weakened, admission: { id, executingPlan in
            await history.bindExecution(request: undo.request, operation: id, plan: executingPlan)
        })
        XCTAssertEqual(result.error, .invalidPlan)
        let exists = await fs.exists(target)
        XCTAssertTrue(exists)
        let state = await history.snapshot()
        let attempts = await history.inverseAttempts()
        XCTAssertEqual(state.pending?.request, undo.request)
        XCTAssertTrue(attempts.isEmpty)
        if exists {
            let retained = try await fs.entry(at: target)
            XCTAssertEqual(retained.objectIdentity, replacement.objectIdentity)
            let legitimate = await executor.execute(undo.plan, admission: { id, executingPlan in
                await history.bindExecution(request: undo.request, operation: id, plan: executingPlan)
            })
            XCTAssertNotNil(legitimate.error)
            let completed = await history.complete(request: undo.request, outcome: legitimate)
            XCTAssertTrue(completed)
            let final = await history.snapshot()
            XCTAssertNil(final.pending)
            XCTAssertEqual(final.undoEntries.count, 1)
        }
    }

    func testAbortBeforeLaunchPreservesHistoryAndRejectsLateBinding() async throws {
        for failure: HistoryPreparationFailure in [.cancelled, .failed("preparation failed")] {
            let (history, executor, fs) = try await seeded()
            let value = await history.beginUndo(recordedOrigins: [:])
            let undo = try XCTUnwrap(value)
            let before = await history.snapshot()
            let journals = await executor.journal.allEntries()
            let stale = await history.abortUndo(request: HistoryRequestID(), failure: failure)
            XCTAssertFalse(stale)
            let aborted = await history.abortUndo(request: undo.request, failure: failure)
            XCTAssertTrue(aborted)
            let duplicate = await history.abortUndo(request: undo.request, failure: failure)
            XCTAssertFalse(duplicate)
            let state = await history.snapshot()
            XCTAssertNil(state.pending)
            XCTAssertEqual(state.undoEntries, before.undoEntries)
            XCTAssertEqual(state.redoEntries, before.redoEntries)
            XCTAssertEqual(state.lastOutcome, failure.outcome)
            let afterJournals = await executor.journal.allEntries()
            XCTAssertEqual(afterJournals.count, journals.count)
            let result = await executor.execute(undo.plan, admission: { id, executingPlan in
                await history.bindExecution(request: undo.request, operation: id, plan: executingPlan)
            })
            XCTAssertEqual(result.error, .invalidPlan)
            let exists = await fs.exists(target)
            XCTAssertTrue(exists)
            let attempts = await history.inverseAttempts()
            XCTAssertTrue(attempts.isEmpty)
            let next = await history.beginUndo(recordedOrigins: [:])
            XCTAssertNotNil(next)
            let oldAbort = await history.abortUndo(request: undo.request, failure: failure)
            XCTAssertFalse(oldAbort)
            let nextUndo = try XCTUnwrap(next)
            _ = await history.abortUndo(request: nextUndo.request, failure: failure)
            let forward = await history.beginForward(.trash(items: [target]))
            XCTAssertNotNil(forward)
        }
    }

    func testBindingWinsAndAbortCannotReleaseRunningUndo() async throws {
        let (history, executor, _) = try await seeded()
        let value = await history.beginUndo(recordedOrigins: [:])
        let undo = try XCTUnwrap(value)
        let result = await executor.execute(undo.plan, admission: { id, executingPlan in
            let bound = await history.bindExecution(request: undo.request, operation: id, plan: executingPlan)
            XCTAssertTrue(bound)
            let aborted = await history.abortUndo(request: undo.request, failure: .cancelled)
            XCTAssertFalse(aborted)
            let state = await history.snapshot()
            XCTAssertEqual(state.pending?.request, undo.request)
            let other = await history.beginUndo(recordedOrigins: [:])
            XCTAssertNil(other)
            return bound
        })
        XCTAssertNil(result.error)
        let completed = await history.complete(request: undo.request, outcome: result)
        XCTAssertTrue(completed)
        let aborted = await history.abortUndo(request: undo.request, failure: .cancelled)
        XCTAssertFalse(aborted)
        let state = await history.snapshot()
        XCTAssertNil(state.pending)
        XCTAssertNil(state.executingOperation)
        XCTAssertTrue(state.undoEntries.isEmpty)
        XCTAssertEqual(state.redoEntries.count, 1)
    }
}
