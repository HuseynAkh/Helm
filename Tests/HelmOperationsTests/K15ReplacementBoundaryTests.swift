// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
@testable import HelmFileSystem
import HelmOperations

final class K15ReplacementBoundaryTests: XCTestCase {
    /// F-052/B-038: staging copy failure retains both originals.
    func testReplacementFailureAtCopy() async throws { try await checkBoundary(0) }
    /// F-052/B-038: verification failure cannot retire the source.
    func testReplacementFailureAtVerify() async throws { try await checkBoundary(1) }
    /// F-052/B-038: backup move failure retains the original target.
    func testReplacementFailureAtBackup() async throws { try await checkBoundary(2) }
    /// F-052/B-038: install failure retains the recoverable backup.
    func testReplacementFailureAtInstall() async throws { try await checkBoundary(3) }
    /// F-052/B-038: backup trash failure retains both payloads.
    func testReplacementFailureAtTrashBackup() async throws { try await checkBoundary(4) }
    /// F-052/B-038: source retirement failure leaves the source recoverable.
    func testReplacementFailureAtRetireSource() async throws { try await checkBoundary(5) }

    private func checkBoundary(_ boundary: Int) async throws {
        let fs = InMemoryFileSystem()
        let source = URL(fileURLWithPath: "/source/file"), parent = URL(fileURLWithPath: "/target")
        try await fs.createDirectory(at: source.deletingLastPathComponent())
        try await fs.createDirectory(at: parent)
        try await fs.createFileExclusively(at: source, contents: Data([1, 2, 3]))
        try await fs.createFileExclusively(at: parent.appendingPathComponent("file"), contents: Data([9, 8]))
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [parent], policy: ConflictPolicy(defaultResolution: .replace))
        let plan = OperationPlanner.plan(.move(sources: [source], destinationDirectory: parent), context: context)
        XCTAssertTrue(plan.isExecutable); XCTAssertEqual(plan.steps.count, 6)
        let step = plan.steps[boundary]
        let injected = try XCTUnwrap(step.kind == .trash || step.kind == .verifyCopy ? step.source : step.destination)
        let executor = OperationExecutor(fileSystem: fs)
        let result = await executor.execute(plan) { progress in
            if progress.itemsDone == boundary && progress.currentName != nil {
                await fs.setFailure(.permissionDenied, at: injected)
            }
        }
        await fs.setFailure(nil, at: injected)
        XCTAssertNotNil(result.error); XCTAssertEqual(result.outcomes.filter(\.succeeded).count, boundary)
        XCTAssertEqual(result.outcomes.count, 6)
        // No step may permanently remove either payload, even when the target has moved to backup/Trash.
        var pending = [URL(fileURLWithPath: "/")]
        var sizes: [Int64] = []
        var payloads: [Data] = []
        while let directory = pending.popLast() {
            for try await batch in fs.enumerate(directory, options: EnumerationOptions(includeHidden: true)) {
                for entry in batch {
                    if entry.kind == .directory { pending.append(entry.url) }
                    else { sizes.append(entry.size); payloads.append(try await fs.storedContents(at: entry.url)) }
                }
            }
        }
        XCTAssertTrue(sizes.contains(2), "Original target lost at boundary \(boundary)")
        XCTAssertTrue(sizes.contains(3), "Original source lost at boundary \(boundary)")
        XCTAssertTrue(payloads.contains(Data([9, 8])), "Original target bytes lost at boundary \(boundary)")
        XCTAssertTrue(payloads.contains(Data([1, 2, 3])), "Original source bytes lost at boundary \(boundary)")
        let original = try await fs.entry(at: source); XCTAssertEqual(original.size, 3)
        let journal = await executor.journal.outcomes(for: result.id)
        XCTAssertEqual(journal.count, 6)
    }
}
