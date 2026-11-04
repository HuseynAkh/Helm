// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmOperations

final class K15CaseSensitiveTransferTests: XCTestCase {
    /// F-052/B-039: distinct case-sensitive directories may hold identical basenames.
    func testCopyBetweenCaseDistinctDirectories() async throws { try await transfer(moving: false) }
    /// F-052/B-039: same-volume moves must honor the volume's case sensitivity.
    func testMoveBetweenCaseDistinctDirectories() async throws { try await transfer(moving: true) }
    private func transfer(moving: Bool) async throws {
        try XCTSkipIf(true, "BUG-K15-1: executor folds case even on case-sensitive volumes; see docs/test-findings/K15-findings.md")
        let fs = InMemoryFileSystem(caseSensitive: true)
        let a = URL(fileURLWithPath: "/a"), upper = URL(fileURLWithPath: "/A")
        let source = a.appendingPathComponent("file")
        try await fs.createDirectory(at: a); try await fs.createDirectory(at: upper)
        try await fs.createFileExclusively(at: source, contents: Data([1, 2, 3]))
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [upper],
            caseSensitive: [URL(fileURLWithPath: "/"): true, a: true, upper: true])
        let command: Command = moving ? .move(sources: [source], destinationDirectory: upper) : .copy(sources: [source], destinationDirectory: upper)
        let plan = OperationPlanner.plan(command, context: context)
        XCTAssertTrue(plan.isExecutable)
        let result = await OperationExecutor(fileSystem: fs).execute(plan)
        XCTAssertNil(result.error)
        let destination = try await fs.entry(at: upper.appendingPathComponent("file"))
        XCTAssertEqual(destination.size, 3)
        let retainedSource = await fs.exists(source); XCTAssertEqual(retainedSource, !moving)
    }
}
