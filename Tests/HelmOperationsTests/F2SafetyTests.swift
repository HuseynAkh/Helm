// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import Foundation
import HelmCore
import HelmFileSystem
@testable import HelmOperations

final class F2SafetyTests: XCTestCase {
    func testSourceIndexComparisonBudget() {
        let count = 1024
        let index = SourcePathIndex(paths: (0..<count).map { "/source/file\($0)" })
        XCTAssertFalse(index.overlaps)
        XCTAssertLessThan(index.comparisons, count * 16)
    }
    func testUndoRefusesTreeWithoutDescendantEvidence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("Project")
        let nested = source.appendingPathComponent("sub/report.txt")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: nested)
        let fs = LiveFileSystem(), executor = OperationExecutor(fileSystem: fs)
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [target])
        let plan = OperationPlanner.plan(.copy(sources: [source], destinationDirectory: target), context: context)
        let refused = await executor.execute(plan)
        XCTAssertEqual(refused.error, .verificationUnavailable)
        XCTAssertEqual(refused.succeededCount, 0)
        let output = target.appendingPathComponent("Project")
        // Native fixture setup remains independent of the conditional executor contract.
        try await fs.copyItem(at: source, to: output)
        let metadata = try await fs.entry(at: output)
        let operationID = await executor.journal.begin(plan)
        let step = try XCTUnwrap(plan.steps.first)
        let outcome = ItemOutcome(step: step, destination: output, result: .success(metadata.changeToken), destinationKind: metadata.kind)
        await executor.journal.record(outcome, for: operationID)
        let copied = OperationResult(id: operationID, command: plan.command, outcomes: [outcome], error: nil)
        await executor.journal.complete(copied)
        let before = try await fs.entry(at: output).changeToken
        try Data([2, 3]).write(to: output.appendingPathComponent("sub/report.txt"))
        let after = try await fs.entry(at: output).changeToken
        XCTAssertEqual(before, after, "Root metadata cannot prove descendant content")
        let stored = await executor.journal.entry(copied.id)
        let inverse = UndoPlanner.inverse(of: try XCTUnwrap(stored), recordedOrigins: [:])
        let result = await executor.execute(inverse)
        XCTAssertEqual(result.error, .verificationUnavailable)
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("sub/report.txt")), Data([2, 3]))
    }
    func testHundredThousandSiblingPlanAndJournal() async {
        let count = 100_000
        let parent = URL(fileURLWithPath: "/target")
        let sources = (0..<count).map { URL(fileURLWithPath: "/source/file\($0)") }
        let context = PlanningContext(caseSensitive: [parent: true, URL(fileURLWithPath: "/source"): true], existingNames: [parent: []])
        let start = Date()
        let plan = OperationPlanner.plan(.copy(sources: sources, destinationDirectory: parent), context: context)
        print("F2 100k copy planning seconds: \(Date().timeIntervalSince(start))")
        XCTAssertTrue(plan.isExecutable)
        XCTAssertEqual(plan.steps.count, count)
        XCTAssertEqual(Set(plan.steps.compactMap(\.destination)).count, count)
        let journal = OperationJournal()
        let id = await journal.begin(plan)
        for step in plan.steps {
            let outcome = ItemOutcome(step: step, destination: step.destination, result: .success(nil))
            await journal.record(outcome, for: id)
            await journal.record(outcome, for: id)
        }
        let recorded = await journal.outcomes(for: id)
        XCTAssertEqual(recorded.count, count)
        XCTAssertEqual(recorded.map { $0.step.id }, plan.steps.map(\.id))
    }
    func testIndexComponentBoundariesAndExclusion() {
        let index = SourcePathIndex(paths: ["/a/x", "/a/xy", "/b/z"])
        XCTAssertFalse(index.overlaps)
        XCTAssertFalse(index.containsSelection(atOrBelow: "/a/x", excluding: "/a/x"))
        XCTAssertTrue(index.containsSelection(atOrBelow: "/a", excluding: "/a/x"))
        XCTAssertFalse(index.containsSelection(atOrBelow: "/a/xyz"))
        XCTAssertTrue(SourcePathIndex(paths: ["/a", "/a/x"]).overlaps)
        XCTAssertTrue(SourcePathIndex(paths: ["/a", "/a"]).overlaps)
    }
    func testKeepBothCopyToAncestorRemainsAllowed() {
        let parent = URL(fileURLWithPath: "/dest")
        let source = URL(fileURLWithPath: "/dest/A/sub/A")
        let plan = OperationPlanner.transfer(sources: [source], to: .directory(parent), moving: false,
            context: PlanningContext(existingNames: [parent: ["A"]]))
        XCTAssertTrue(plan.isExecutable)
        XCTAssertEqual(plan.steps.first?.destination?.lastPathComponent, "A 2")
    }
    func testCancelledStartedCopyKeepsExecutorBusyAndJournalsCompletion() async throws {
        let fs = InMemoryFileSystem()
        let source = URL(fileURLWithPath: "/source"), target = URL(fileURLWithPath: "/target")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        let started = expectation(description: "Copy entered native body")
        let gate = DispatchSemaphore(value: 0)
        let copier = F2GatedCopier(fileSystem: fs, executor: IOExecutor(timeout: 5), gate: gate, started: { started.fulfill() })
        let executor = OperationExecutor(fileSystem: fs, copier: copier)
        let plan = OperationPlan(command: .recovery, steps: [PlannedStep(kind: .copy, source: source, destination: target),
            PlannedStep(kind: .createFile, destination: URL(fileURLWithPath: "/later"))])
        let task = Task { await executor.execute(plan) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let concurrent = await executor.execute(plan)
        XCTAssertEqual(concurrent.error, .busy)
        gate.signal()
        let result = await task.value
        XCTAssertEqual(result.error, .cancelled)
        XCTAssertTrue(result.outcomes[0].succeeded)
        XCTAssertFalse(result.outcomes[1].succeeded)
        let exists = await fs.exists(target)
        XCTAssertTrue(exists)
        let stored = await executor.journal.outcomes(for: result.id)
        XCTAssertTrue(stored[0].succeeded)
    }
    func testReplaceAncestorUsesDestinationCaseSemantics() {
        let source = URL(fileURLWithPath: "/dest/A/sub/A"), parent = URL(fileURLWithPath: "/dest")
        let context = PlanningContext(caseSensitive: [parent: true], existingNames: [parent: ["A"]],
            defaultPolicy: ConflictPolicy(defaultResolution: .replace))
        let plan = OperationPlanner.transfer(sources: [source], to: .directory(parent), moving: false, context: context)
        XCTAssertFalse(plan.isExecutable)
        XCTAssertTrue(plan.steps.isEmpty)
    }
    func testCopyReplaceAncestorRefused() { checkAncestor(moving: false) }
    func testMoveReplaceAncestorRefused() { checkAncestor(moving: true) }
    private func checkAncestor(moving: Bool) {
        let source = URL(fileURLWithPath: "/dest/A/sub/A"), parent = URL(fileURLWithPath: "/dest")
        let context = PlanningContext(existingNames: [parent: ["A"]], defaultPolicy: ConflictPolicy(defaultResolution: .replace))
        let plan = OperationPlanner.transfer(sources: [source], to: .directory(parent), moving: moving, context: context)
        XCTAssertFalse(plan.isExecutable)
        XCTAssertTrue(plan.steps.isEmpty)
    }
    func testUndoRechecksAfterProgress() async throws {
        let fs = InMemoryFileSystem(), a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b")
        try await fs.createFileExclusively(at: a, contents: Data([1]))
        try await fs.createFileExclusively(at: b, contents: Data([2]))
        let tokens = try await [a: fs.entry(at: a).changeToken, b: fs.entry(at: b).changeToken]
        let plan = OperationPlan(command: .recovery, steps: [PlannedStep(kind: .trash, source: a), PlannedStep(kind: .trash, source: b)], expectedTokens: tokens)
        let result = await OperationExecutor(fileSystem: fs).execute(plan) { progress in
            if progress.itemsDone == 1 && progress.currentName != nil {
                try? await fs.removeItem(at: b)
                try? await fs.createFileExclusively(at: b, contents: Data([3, 4]))
            }
        }
        XCTAssertEqual(result.error, .sourceChanged(b))
        let retained = await fs.exists(b)
        XCTAssertTrue(retained)
    }
}

private struct F2GatedCopier: FileCopier {
    let fileSystem: InMemoryFileSystem
    let executor: IOExecutor
    let gate: DispatchSemaphore
    let started: @Sendable () -> Void
    func copy(from source: URL, to destination: URL) async throws {
        try await copy(from: source, to: destination, requiring: fileSystem.mutationPrecondition(at: source))
    }
    func copy(from source: URL, to destination: URL, requiring precondition: FileMutationPrecondition) async throws {
        // Once admitted, this fixture models a non-cancellable native body that completes.
        try await Task.detached {
            try await executor.run { started(); gate.wait() }
            _ = try await fileSystem.mutate(.copy(to: destination), source: source, requiring: precondition)
        }.value
    }
}
