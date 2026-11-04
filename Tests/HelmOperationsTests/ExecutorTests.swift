// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import Foundation
import HelmCore
import HelmFileSystem
import HelmTestKit
@testable import HelmOperations

final class ExecutorTests: XCTestCase {
    let a = URL(fileURLWithPath: "/a")
    let b = URL(fileURLWithPath: "/b")
    func fixture() async throws -> InMemoryFileSystem {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: a); try await fs.createDirectory(at: b)
        try await fs.createFileExclusively(at: a.appendingPathComponent("x"), contents: Data([1, 2, 3]))
        try await fs.createFileExclusively(at: a.appendingPathComponent("y"), contents: Data([4]))
        return fs
    }
    func testCopyAndUndoRoundTripWithExactJournalPaths() async throws {
        let fs = try await fixture(), source = a.appendingPathComponent("x")
        let origins = InMemoryTrashOrigins(), journal = OperationJournal()
        let executor = OperationExecutor(fileSystem: fs, origins: origins, journal: journal)
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [b])
        let result = await executor.execute(OperationPlanner.plan(.copy(sources: [source], destinationDirectory: b), context: context))
        XCTAssertNil(result.error); XCTAssertEqual(result.succeededCount, 1)
        let stored = await journal.entry(result.id)
        let entry = try XCTUnwrap(stored)
        let undo = await UndoPlanner.inverse(of: entry, origins: origins)
        XCTAssertEqual(undo.steps.map(\.kind), [.trash])
        let undone = await executor.execute(undo)
        XCTAssertNil(undone.error)
        let originalExists = await fs.exists(source), copyExists = await fs.exists(b.appendingPathComponent("x"))
        XCTAssertTrue(originalExists); XCTAssertFalse(copyExists)
        let repeated = await journal.complete(result); XCTAssertFalse(repeated)
        let affected = result.affectedDirectories.map(\.path)
        XCTAssertTrue(affected.contains("/b"))
    }
    func testSwapRenameAndUndoPreserveSizes() async throws {
        let fs = try await fixture(), x = a.appendingPathComponent("x"), y = a.appendingPathComponent("y")
        let pairs = [RenamePair(source: x, newName: try XCTUnwrap(ValidFileName("y"))), RenamePair(source: y, newName: try XCTUnwrap(ValidFileName("x")))]
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [x, y], destinations: [a])
        let executor = OperationExecutor(fileSystem: fs)
        let result = await executor.execute(OperationPlanner.plan(.batchRename(pairs), context: context))
        XCTAssertNil(result.error)
        let swapped = try await fs.entry(at: x); XCTAssertEqual(swapped.size, 1)
        let stored = await executor.journal.entry(result.id)
        let undo = UndoPlanner.inverse(of: try XCTUnwrap(stored), recordedOrigins: [:])
        let reversed = await executor.execute(undo); XCTAssertNil(reversed.error)
        let restored = try await fs.entry(at: x); XCTAssertEqual(restored.size, 3)
        let names = try await fs.childNames(of: a); XCTAssertEqual(names, ["x", "y"])
    }
    func testReplaceStagesBeforeRetiringAndUndoRestoresOriginal() async throws {
        let fs = try await fixture(), source = a.appendingPathComponent("x"), target = b.appendingPathComponent("x")
        try await fs.createFileExclusively(at: target, contents: Data([9]))
        let origins = InMemoryTrashOrigins(), executor = OperationExecutor(fileSystem: fs, origins: origins)
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [b], policy: ConflictPolicy(defaultResolution: .replace))
        let result = await executor.execute(OperationPlanner.plan(.copy(sources: [source], destinationDirectory: b), context: context))
        XCTAssertNil(result.error); XCTAssertEqual(result.succeededCount, 5)
        let replaced = try await fs.entry(at: target); XCTAssertEqual(replaced.size, 3)
        let stored = await executor.journal.entry(result.id)
        let undo = await UndoPlanner.inverse(of: try XCTUnwrap(stored), origins: origins)
        let reversed = await executor.execute(undo); XCTAssertNil(reversed.error)
        let restored = try await fs.entry(at: target); XCTAssertEqual(restored.size, 1)
        let names = try await fs.childNames(of: b); XCTAssertEqual(names, ["x"])
    }
    func testFailureAtEveryReplacementBoundaryKeepsOriginalOrBackup() async throws {
        for index in 0..<5 {
            let fs = try await fixture(), source = a.appendingPathComponent("x"), target = b.appendingPathComponent("x")
            try await fs.createFileExclusively(at: target, contents: Data([9]))
            let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [b], policy: ConflictPolicy(defaultResolution: .replace))
            let plan = OperationPlanner.plan(.copy(sources: [source], destinationDirectory: b), context: context)
            let failed = plan.steps[index]
            let failureURL = try XCTUnwrap(failed.kind == .verifyCopy || failed.kind == .trash ? failed.source : failed.destination)
            let executor = OperationExecutor(fileSystem: fs)
            let result = await executor.execute(plan) { progress in
                if progress.itemsDone == index && progress.currentName != nil { await fs.setFailure(.permissionDenied, at: failureURL) }
            }
            XCTAssertNotNil(result.error, "boundary \(index)")
            XCTAssertEqual(result.succeededCount, index); XCTAssertEqual(result.outcomes.count, 5)
            await fs.setFailure(nil, at: failureURL)
            let sourceEntry = try await fs.entry(at: source); XCTAssertEqual(sourceEntry.size, 3)
            let oldLocation = index >= 3 ? try XCTUnwrap(plan.steps[2].destination) : target
            let oldEntry = try await fs.entry(at: oldLocation); XCTAssertEqual(oldEntry.size, 1)
            let logged = await executor.journal.outcomes(for: result.id); XCTAssertEqual(logged.count, 5)
        }
    }
    func testFailureKeepsEarlierOutcomesAndStopsLaterItems() async throws {
        let fs = try await fixture(), x = a.appendingPathComponent("x"), y = a.appendingPathComponent("y")
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [x, y], destinations: [b])
        await fs.setFailure(.permissionDenied, at: y)
        let executor = OperationExecutor(fileSystem: fs)
        let result = await executor.execute(OperationPlanner.plan(.copy(sources: [x, y], destinationDirectory: b), context: context))
        XCTAssertEqual(result.succeededCount, 1); XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.outcomes[0].step.source, x); XCTAssertEqual(result.outcomes[0].destination, b.appendingPathComponent("x"))
        let stored = await executor.journal.entry(result.id)
        XCTAssertFalse(UndoPlanner.inverse(of: try XCTUnwrap(stored), recordedOrigins: [:]).isExecutable)
    }
    func testExecutionTimeCollisionUsesNumbering() async throws {
        let fs = try await fixture(), source = a.appendingPathComponent("x")
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [b])
        let plan = OperationPlanner.plan(.copy(sources: [source], destinationDirectory: b), context: context)
        try await fs.createFileExclusively(at: b.appendingPathComponent("x"), contents: Data([8]))
        let result = await OperationExecutor(fileSystem: fs).execute(plan)
        XCTAssertNil(result.error); XCTAssertEqual(result.outcomes.first?.destination?.lastPathComponent, "x 2")
        let old = try await fs.entry(at: b.appendingPathComponent("x")); XCTAssertEqual(old.size, 1)
    }
    func testCrossVolumeVerificationThenTrashAndUndo() async throws {
        let fs = try await fixture(), source = a.appendingPathComponent("x")
        let built = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [b])
        let context = PlanningContext(sourceManifest: built.sourceManifest, existingNames: built.existingNames)
        let origins = InMemoryTrashOrigins(), executor = OperationExecutor(fileSystem: fs, origins: origins)
        let result = await executor.execute(OperationPlanner.plan(.move(sources: [source], destinationDirectory: b), context: context))
        XCTAssertNil(result.error); XCTAssertEqual(result.succeededCount, 3)
        let exists = await fs.exists(source); XCTAssertFalse(exists)
        let stored = await executor.journal.entry(result.id)
        let undo = await UndoPlanner.inverse(of: try XCTUnwrap(stored), origins: origins)
        let reversed = await executor.execute(undo); XCTAssertNil(reversed.error)
        let restored = try await fs.entry(at: source); XCTAssertEqual(restored.size, 3)
    }
    func testFailedVerificationNeverRetiresSource() async throws {
        let fs = try await fixture(), source = a.appendingPathComponent("x")
        let built = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [b])
        let context = PlanningContext(sourceManifest: built.sourceManifest, existingNames: built.existingNames)
        let executor = OperationExecutor(fileSystem: fs, verifier: UnavailableCopyVerifier())
        let result = await executor.execute(OperationPlanner.plan(.move(sources: [source], destinationDirectory: b), context: context))
        XCTAssertEqual(result.error, .verificationUnavailable); XCTAssertEqual(result.succeededCount, 1)
        let exists = await fs.exists(source); XCTAssertTrue(exists)
    }
    func testCancellationBetweenStepsPreservesFirstCopy() async throws {
        let fs = try await fixture(), x = a.appendingPathComponent("x"), y = a.appendingPathComponent("y")
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [x, y], destinations: [b])
        let plan = OperationPlanner.plan(.copy(sources: [x, y], destinationDirectory: b), context: context)
        let task = Task {
            await OperationExecutor(fileSystem: fs).execute(plan) { progress in
                if progress.itemsDone == 1 && progress.currentName != nil { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let result = await task.value
        XCTAssertTrue(result.wasCancelled); XCTAssertEqual(result.succeededCount, 1)
        let names = try await fs.childNames(of: b); XCTAssertEqual(names, ["x"])
    }
    func testCancellationBeforeStartAndInvalidPlanHaveNoMutations() async throws {
        let fs = try await fixture()
        let executor = OperationExecutor(fileSystem: fs)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await executor.execute(OperationPlan(command: .recovery, steps: [PlannedStep(kind: .createFile, destination: b.appendingPathComponent("new"))]))
        }
        let result = await task.value; XCTAssertTrue(result.wasCancelled); XCTAssertEqual(result.succeededCount, 0)
        let bad = await executor.execute(OperationPlan(command: .recovery, steps: [], issues: [.virtualLocationTarget]))
        XCTAssertEqual(bad.error, .invalidPlan)
    }
    func testTimeoutQuarantinesExecutor() async throws {
        let fs = try await fixture(), source = a.appendingPathComponent("x")
        await fs.setFailure(.timedOut, at: source)
        let executor = OperationExecutor(fileSystem: fs)
        let plan = OperationPlan(command: .recovery, steps: [PlannedStep(kind: .copy, source: source, destination: b.appendingPathComponent("x"))])
        let first = await executor.execute(plan), second = await executor.execute(plan)
        XCTAssertEqual(first.error, .timedOut); XCTAssertEqual(second.error, .busy)
    }
    func testLiveTemporaryDirectoryCopyAndCreate() async throws {
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        let fs = LiveFileSystem()
        let source = temp.url.appendingPathComponent("source"), parent = temp.url.appendingPathComponent("target")
        try await fs.createFileExclusively(at: source, contents: Data("hello".utf8))
        try await fs.createDirectory(at: parent)
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [parent])
        let executor = OperationExecutor(fileSystem: fs)
        let result = await executor.execute(OperationPlanner.plan(.copy(sources: [source], destinationDirectory: parent), context: context))
        XCTAssertNil(result.error)
        XCTAssertEqual(try Data(contentsOf: parent.appendingPathComponent("source")), Data("hello".utf8))
        let name = try XCTUnwrap(ValidFileName("new.txt"))
        let created = await executor.execute(OperationPlanner.plan(.createFile(parent: parent, name: name, template: nil), context: context))
        XCTAssertNil(created.error)
    }
}
