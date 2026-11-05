// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmFileSystem
@testable import HelmOperations

final class K34AtomicExecutorTests: XCTestCase {
    func testSubstitutionAfterLastPreflightIsRefusedByMutationBoundary() async throws {
        let fs = InMemoryFileSystem(), source = URL(fileURLWithPath: "/source"), destination = URL(fileURLWithPath: "/output")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        let executor = OperationExecutor(fileSystem: fs, copier: K34SubstitutionCopier(fileSystem: fs), origins: InMemoryTrashOrigins())
        let result = await executor.execute(OperationPlan(command: .recovery, steps: [PlannedStep(kind: .copy, source: source, destination: destination)]))
        XCTAssertEqual(result.error, .sourceChanged(source))
        XCTAssertEqual(result.succeededCount, 0)
        XCTAssertFalse(try XCTUnwrap(result.outcomes.first).requiresReconciliation)
        let outputExists = await fs.exists(destination), sourceExists = await fs.exists(source)
        XCTAssertFalse(outputExists); XCTAssertTrue(sourceExists)
    }
    func testUnadoptedCopierRefusesWithoutCallingLegacyMutation() async throws {
        let fs = InMemoryFileSystem(), source = URL(fileURLWithPath: "/source")
        try await fs.createFileExclusively(at: source, contents: Data())
        let executor = OperationExecutor(fileSystem: fs, copier: K34LegacyCopier(), origins: InMemoryTrashOrigins())
        let result = await executor.execute(OperationPlan(command: .recovery, steps: [PlannedStep(kind: .copy, source: source, destination: URL(fileURLWithPath: "/output"))]))
        XCTAssertEqual(result.error, .verificationUnavailable)
        XCTAssertFalse(try XCTUnwrap(result.outcomes.first).requiresReconciliation)
    }
}
private struct K34SubstitutionCopier: FileCopier {
    let fileSystem: InMemoryFileSystem
    func copy(from source: URL, to destination: URL) async throws { XCTFail("Unconditional copy called") }
    func copy(from source: URL, to destination: URL, requiring precondition: FileMutationPrecondition) async throws {
        try await fileSystem.removeItem(at: source)
        try await fileSystem.createFileExclusively(at: source, contents: Data([2]))
        _ = try await fileSystem.mutate(.copy(to: destination), source: source, requiring: precondition)
    }
}
private struct K34LegacyCopier: FileCopier {
    func copy(from source: URL, to destination: URL) async throws { XCTFail("Legacy copy must not be called") }
}
