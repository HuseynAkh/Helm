// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import HelmCore
import HelmFileSystem
import HelmOperations

final class CapabilityIntegrationTests: XCTestCase {
    func testBuilderQueriesCapabilitiesAndPreservesExplicitOverrides() async throws {
        let root = URL(fileURLWithPath: "/")
        let fs = InMemoryFileSystem(caseSensitive: true)
        let builder = PlanningContextBuilder(fileSystem: fs)
        let inferred = try await builder.build(sources: [], destinations: [root])
        XCTAssertEqual(inferred.caseSensitive[root], true)
        let overridden = try await builder.build(sources: [], destinations: [root], caseSensitive: [root: false])
        XCTAssertEqual(overridden.caseSensitive[root], false)
    }

    func testExecutorQueriesMissingSourceSensitivity() async throws {
        let fs = InMemoryFileSystem(caseSensitive: true)
        let source = URL(fileURLWithPath: "/a")
        let destination = URL(fileURLWithPath: "/A")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        let plan = OperationPlan(command: .recovery,
                                 steps: [PlannedStep(kind: .copy, source: source, destination: destination)],
                                 context: PlanningContext())
        let result = await OperationExecutor(fileSystem: fs, origins: InMemoryTrashOrigins()).execute(plan)
        XCTAssertNil(result.error)
        let exists = await fs.exists(destination)
        XCTAssertTrue(exists)
    }

    func testTypedCollisionRetriesOnlyWithNoMutationGuarantee() async throws {
        for safe in [true, false] {
            let fs = InMemoryFileSystem()
            let source = URL(fileURLWithPath: "/source")
            let destination = URL(fileURLWithPath: "/target")
            try await fs.createFileExclusively(at: source, contents: Data([1]))
            let copier = CollisionCopier(fileSystem: fs, safe: safe)
            let plan = OperationPlan(command: .recovery,
                steps: [PlannedStep(kind: .copy, source: source, destination: destination, retryKeepBoth: true)],
                context: PlanningContext())
            let result = await OperationExecutor(fileSystem: fs, copier: copier, origins: InMemoryTrashOrigins()).execute(plan)
            let attempts = await copier.attempts
            XCTAssertEqual(attempts, safe ? 2 : 1)
            if safe {
                XCTAssertNil(result.error)
                XCTAssertEqual(result.succeededCount, 1)
                XCTAssertNotEqual(result.outcomes.first?.destination, destination)
            } else {
                XCTAssertNotNil(result.error)
                XCTAssertEqual(result.outcomes.first?.requiresReconciliation, true)
            }
        }
    }
}

private actor CollisionCopier: FileCopier {
    let fileSystem: InMemoryFileSystem
    let safe: Bool
    var attempts = 0
    init(fileSystem: InMemoryFileSystem, safe: Bool) { self.fileSystem = fileSystem; self.safe = safe }
    func copy(from source: URL, to destination: URL) async throws {
        try await copy(from: source, to: destination, requiring: fileSystem.mutationPrecondition(at: source))
    }
    func copy(from source: URL, to destination: URL, requiring precondition: FileMutationPrecondition) async throws {
        attempts += 1
        if attempts == 1 { throw FileSystemError.collision(noMutation: safe) }
        _ = try await fileSystem.mutate(.copy(to: destination), source: source, requiring: precondition)
    }
}
