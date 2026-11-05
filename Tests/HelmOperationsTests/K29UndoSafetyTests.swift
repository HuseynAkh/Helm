// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmFileSystem
@testable import HelmOperations

final class K29UndoSafetyTests: XCTestCase {
    func testMovedDirectoryWithEditedDescendantRefusesUndoBeforeAnyMutation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = root.appendingPathComponent("Project")
        let nested = original.appendingPathComponent("sub/report.txt")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: nested)
        let fs = LiveFileSystem(), executor = OperationExecutor(fileSystem: fs)
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [original], destinations: [target])
        let plan = OperationPlanner.plan(.move(sources: [original], destinationDirectory: target), context: context)
        let refused = await executor.execute(plan)
        XCTAssertEqual(refused.error, .verificationUnavailable)
        XCTAssertEqual(refused.succeededCount, 0)
        let output = target.appendingPathComponent("Project")
        // Native fixture setup remains independent of the conditional executor contract.
        try await fs.moveItem(at: original, to: output)
        let metadata = try await fs.entry(at: output)
        let operationID = await executor.journal.begin(plan)
        let step = try XCTUnwrap(plan.steps.first)
        let outcome = ItemOutcome(step: step, destination: output, result: .success(metadata.changeToken), destinationKind: metadata.kind)
        await executor.journal.record(outcome, for: operationID)
        let result = OperationResult(id: operationID, command: plan.command, outcomes: [outcome], error: nil)
        await executor.journal.complete(result)
        let before = try await fs.entry(at: output).changeToken
        try Data([2, 3]).write(to: output.appendingPathComponent("sub/report.txt"))
        let after = try await fs.entry(at: output).changeToken
        XCTAssertEqual(before, after)
        let stored = await executor.journal.entry(result.id)
        let inverse = UndoPlanner.inverse(of: try XCTUnwrap(stored), recordedOrigins: [:])
        XCTAssertEqual(inverse.undoVerification, .leafOnly)
        let recordedOutput = try XCTUnwrap(result.outcomes.last?.destination)
        XCTAssertEqual(recordedOutput.path, output.path)
        XCTAssertEqual(inverse.expectedKinds[recordedOutput], .directory)
        let undone = await executor.execute(inverse)
        XCTAssertEqual(undone.error, .verificationUnavailable)
        XCTAssertEqual(undone.succeededCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try Data(contentsOf: output.appendingPathComponent("sub/report.txt")), Data([2, 3]))
    }
    func testUnchangedDirectoryAndPackageStillRequireDescendantEvidence() async throws {
        for kind in [FileEntryKind.directory, .package] {
            let fs = InMemoryFileSystem()
            let path = URL(fileURLWithPath: "/tree")
            try await fs.createDirectory(at: path)
            let metadata = try await fs.entry(at: path)
            let plan = OperationPlan(command: .recovery, steps: [PlannedStep(kind: .move, source: path, destination: URL(fileURLWithPath: "/restored"))],
                                     expectedTokens: [path: metadata.changeToken], undoVerification: .leafOnly, expectedKinds: [path: kind])
            let result = await OperationExecutor(fileSystem: fs).execute(plan)
            XCTAssertEqual(result.error, .verificationUnavailable)
            let stillPresent = try await fs.entry(at: path)
            XCTAssertEqual(stillPresent.kind, .directory)
        }
    }
    func testMissingKindAndMissingTokenFailClosed() async throws {
        for missingKind in [true, false] {
            let fs = InMemoryFileSystem(), path = URL(fileURLWithPath: "/file")
            try await fs.createFileExclusively(at: path, contents: Data([7]))
            let entry = try await fs.entry(at: path)
            let plan = OperationPlan(command: .recovery, steps: [PlannedStep(kind: .trash, source: path)],
                                     expectedTokens: missingKind ? [path: entry.changeToken] : [:], undoVerification: .leafOnly,
                                     expectedKinds: missingKind ? [:] : [path: .regular])
            let result = await OperationExecutor(fileSystem: fs).execute(plan)
            XCTAssertEqual(result.error, .verificationUnavailable)
            let retained = try await fs.entry(at: path)
            XCTAssertEqual(retained.size, 1)
        }
    }
    func testKindChangeWithEqualTokenRefusesLeafUndo() async throws {
        let fs = InMemoryFileSystem(), path = URL(fileURLWithPath: "/file")
        try await fs.createFileExclusively(at: path, contents: Data([7]))
        let entry = try await fs.entry(at: path)
        let plan = OperationPlan(command: .recovery, steps: [PlannedStep(kind: .trash, source: path)],
                                 expectedTokens: [path: entry.changeToken], undoVerification: .leafOnly,
                                 expectedKinds: [path: .symlinkToFile])
        let result = await OperationExecutor(fileSystem: fs).execute(plan)
        XCTAssertEqual(result.error, .sourceChanged(path))
    }
}
