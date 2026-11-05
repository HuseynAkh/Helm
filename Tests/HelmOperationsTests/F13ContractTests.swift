// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import Foundation
import HelmCore
import HelmFileSystem
import HelmOperations

final class F13ContractTests: XCTestCase {
    func testP8IdentityReplacementMustSurviveUndo() async throws {
        let fs = InMemoryFileSystem()
        let output = URL(fileURLWithPath: "/output")
        let saved = URL(fileURLWithPath: "/saved-metadata")
        let executor = OperationExecutor(fileSystem: fs)
        let result = await executor.execute(OperationPlan(command: .recovery, steps: [PlannedStep(kind: .createFile, destination: output, contents: Data([1]))]))
        XCTAssertNil(result.error)
        let before = try await fs.entry(at: output)
        try await fs.createFileExclusively(at: saved, contents: Data([1]))
        try await fs.applyDirectoryMetadata(from: output, to: saved)
        try await fs.removeItem(at: output)
        try await fs.createFileExclusively(at: output, contents: Data([2]))
        try await fs.applyDirectoryMetadata(from: saved, to: output)
        let replacement = try await fs.entry(at: output)
        XCTAssertEqual(before.changeToken, replacement.changeToken)
        XCTAssertNotEqual(before.objectIdentity, replacement.objectIdentity)
        let stored = await executor.journal.entry(result.id)
        let inverse = UndoPlanner.inverse(of: try XCTUnwrap(stored), recordedOrigins: [:])
        let undo = await executor.execute(inverse)
        let exists = await fs.exists(output)
        XCTAssertEqual(undo.succeededCount, 0, "P8-1: undo must refuse a different object")
        XCTAssertTrue(exists, "P8-1: replacement must survive")
    }
    func testP8PreAdmissionCancellationMustNotQuarantine() async throws {
        let fs = InMemoryFileSystem()
        let source = URL(fileURLWithPath: "/source"), output = URL(fileURLWithPath: "/output")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        let executor = OperationExecutor(fileSystem: fs, copier: CancelBeforeAdmission(fs: fs))
        let task = Task { await executor.execute(OperationPlan(command: .recovery, steps: [PlannedStep(kind: .copy, source: source, destination: output)])) }
        let result = await task.value
        XCTAssertEqual(result.error, .cancelled)
        let exists = await fs.exists(output)
        XCTAssertFalse(exists)
        XCTAssertFalse(try XCTUnwrap(result.outcomes.first).requiresReconciliation, "P8-2: admission performed no mutation")
        let next = await executor.execute(OperationPlan(command: .recovery, steps: [PlannedStep(kind: .createFile, destination: URL(fileURLWithPath: "/next"))]))
        XCTAssertNil(next.error, "P8-2: clean executor must remain usable")
    }
}
private struct CancelBeforeAdmission: FileCopier {
    let fs: InMemoryFileSystem
    func copy(from source: URL, to destination: URL) async throws { XCTFail("Unconditional mutation") }
    func copy(from source: URL, to destination: URL, requiring evidence: FileMutationPrecondition) async throws {
        withUnsafeCurrentTask { $0?.cancel() }
        _ = try await fs.mutate(.copy(to: destination), source: source, requiring: evidence)
    }
}
