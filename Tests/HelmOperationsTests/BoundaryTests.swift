// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import Foundation
import HelmCore
import HelmFileSystem
@testable import HelmOperations

final class BoundaryTests: XCTestCase {
    func testFailureAtEverySwapBoundaryJournalsExactPrefix() async throws {
        for index in 0..<4 {
            let fs = InMemoryFileSystem(), root = URL(fileURLWithPath: "/root")
            try await fs.createDirectory(at: root)
            let x = root.appendingPathComponent("x"), y = root.appendingPathComponent("y")
            try await fs.createFileExclusively(at: x, contents: Data([1, 2]))
            try await fs.createFileExclusively(at: y, contents: Data([3]))
            let pairs = [RenamePair(source: x, newName: try XCTUnwrap(ValidFileName("y"))), RenamePair(source: y, newName: try XCTUnwrap(ValidFileName("x")))]
            let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [x, y], destinations: [root])
            let plan = OperationPlanner.plan(.batchRename(pairs), context: context)
            let destination = try XCTUnwrap(plan.steps[index].destination)
            let result = await OperationExecutor(fileSystem: fs).execute(plan) { progress in
                if progress.itemsDone == index && progress.currentName != nil { await fs.setFailure(.permissionDenied, at: destination) }
            }
            XCTAssertEqual(result.succeededCount, index); XCTAssertNotNil(result.error)
            XCTAssertEqual(Array(result.outcomes.prefix(index)).map(\.destination), Array(plan.steps.prefix(index)).map(\.destination))
            await fs.setFailure(nil, at: destination)
            var sizes: [Int64] = []
            for try await batch in fs.enumerate(root, options: EnumerationOptions(includeHidden: true)) { sizes += batch.map(\.size) }
            XCTAssertEqual(sizes.sorted(), [1, 2])
        }
    }
    func testPartialCutAcknowledgesOnlyCompletedOriginalSources() async throws {
        let fs = InMemoryFileSystem(), source = URL(fileURLWithPath: "/a"), failed = URL(fileURLWithPath: "/b"), parent = URL(fileURLWithPath: "/target")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        try await fs.createFileExclusively(at: failed, contents: Data([2]))
        try await fs.createDirectory(at: parent)
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source, failed], destinations: [parent])
        await fs.setFailure(.permissionDenied, at: failed)
        let result = await OperationExecutor(fileSystem: fs).execute(OperationPlanner.plan(.move(sources: [source, failed], destinationDirectory: parent), context: context))
        XCTAssertEqual(result.completedMoveSources, [source])
        let clipboard = ClipboardTransaction(mode: .cut, sources: [source, failed], changeCount: 8)
        XCTAssertEqual(clipboard.acknowledging(result.completedMoveSources, currentChangeCount: 8)?.sources, [failed])
    }
    func testCancellationPrefixCanBeUndone() async throws {
        let fs = InMemoryFileSystem(), executor = OperationExecutor(fileSystem: fs)
        let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b")
        let plan = OperationPlan(command: .recovery, steps: [PlannedStep(kind: .createFile, destination: a), PlannedStep(kind: .createFile, destination: b)])
        let task = Task {
            await executor.execute(plan) { progress in
                if progress.itemsDone == 1 && progress.currentName != nil { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        let result = await task.value
        let stored = await executor.journal.entry(result.id)
        let inverse = UndoPlanner.inverse(of: try XCTUnwrap(stored), recordedOrigins: [:])
        XCTAssertTrue(inverse.isExecutable); XCTAssertEqual(inverse.steps.count, 1)
        let undo = await executor.execute(inverse); XCTAssertNil(undo.error)
        let exists = await fs.exists(a); XCTAssertFalse(exists)
    }
    func testSourceChangedBeforeRetirementIsRetained() async throws { try await changedSource(at: 2) }
    func testSourceChangedBeforeVerificationIsRetained() async throws { try await changedSource(at: 1) }
    private func changedSource(at boundary: Int) async throws {
        let fs = InMemoryFileSystem(), source = URL(fileURLWithPath: "/source"), parent = URL(fileURLWithPath: "/target")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        try await fs.createDirectory(at: parent)
        let built = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [parent])
        let context = PlanningContext(sourceManifest: built.sourceManifest, existingNames: built.existingNames)
        let plan = OperationPlanner.plan(.move(sources: [source], destinationDirectory: parent), context: context)
        let result = await OperationExecutor(fileSystem: fs).execute(plan) { progress in
            if progress.itemsDone == boundary && progress.currentName != nil {
                do {
                    _ = try await fs.trashItem(at: source)
                    try await fs.createFileExclusively(at: source, contents: Data([2, 3]))
                } catch { XCTFail("Fixture mutation failed: \(error)") }
            }
        }
        XCTAssertEqual(result.error, .verificationFailed)
        let current = try await fs.entry(at: source); XCTAssertEqual(current.size, 2)
    }
}
