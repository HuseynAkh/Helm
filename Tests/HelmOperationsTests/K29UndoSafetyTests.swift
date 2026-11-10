// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmFileSystem
@testable import HelmOperations

final class K29UndoSafetyTests: XCTestCase {
    /// Undo of a move puts it back, edits included. Nothing is lost, and Finder allows this (O1-1).
    func testUndoOfMovedDirectoryRestoresItWithEditedDescendant() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = root.appendingPathComponent("Project")
        let nested = original.appendingPathComponent("sub/report.txt")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: nested)
        let fs = LiveFileSystem(), executor = OperationExecutor(fileSystem: fs, origins: InMemoryTrashOrigins())
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [original], destinations: [target])
        let plan = OperationPlanner.plan(.move(sources: [original], destinationDirectory: target), context: context)
        let moved = await executor.execute(plan)
        XCTAssertNil(moved.error)
        XCTAssertEqual(moved.succeededCount, 1)
        let output = target.appendingPathComponent("Project")
        try Data([2, 3]).write(to: output.appendingPathComponent("sub/report.txt"))
        let stored = await executor.journal.entry(moved.id)
        let inverse = UndoPlanner.inverse(of: try XCTUnwrap(stored), recordedOrigins: [:])
        XCTAssertEqual(inverse.undoVerification, .sameObject)
        let undone = await executor.execute(inverse)
        XCTAssertNil(undone.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertEqual(try Data(contentsOf: nested), Data([2, 3]))
    }

    /// A different object at the recorded path is not the thing we moved: refuse and touch nothing.
    func testUndoRefusesWhenAnotherObjectTookThePath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let original = root.appendingPathComponent("a.txt")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: original)
        let fs = LiveFileSystem(), executor = OperationExecutor(fileSystem: fs, origins: InMemoryTrashOrigins())
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [original], destinations: [target])
        let moved = await executor.execute(OperationPlanner.plan(.move(sources: [original], destinationDirectory: target), context: context))
        XCTAssertNil(moved.error)
        let output = target.appendingPathComponent("a.txt")
        try FileManager.default.removeItem(at: output)
        try Data([9]).write(to: output)
        let stored = await executor.journal.entry(moved.id)
        let undone = await executor.execute(UndoPlanner.inverse(of: try XCTUnwrap(stored), recordedOrigins: [:]))
        XCTAssertNotNil(undone.error)
        XCTAssertEqual(undone.succeededCount, 0)
        XCTAssertEqual(try Data(contentsOf: output), Data([9]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }
    func testUnchangedDirectoryAndPackageStillRequireDescendantEvidence() async throws {
        for kind in [FileEntryKind.directory, .package] {
            let fs = InMemoryFileSystem()
            let path = URL(fileURLWithPath: "/tree")
            try await fs.createDirectory(at: path)
            let metadata = try await fs.entry(at: path)
            let plan = OperationPlan(command: .recovery, steps: [PlannedStep(kind: .move, source: path, destination: URL(fileURLWithPath: "/restored"))],
                                     expectedTokens: [path: metadata.changeToken], undoVerification: .leafOnly, expectedKinds: [path: kind])
            let result = await OperationExecutor(fileSystem: fs, origins: InMemoryTrashOrigins()).execute(plan)
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
            let result = await OperationExecutor(fileSystem: fs, origins: InMemoryTrashOrigins()).execute(plan)
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
        let result = await OperationExecutor(fileSystem: fs, origins: InMemoryTrashOrigins()).execute(plan)
        XCTAssertEqual(result.error, .sourceChanged(path))
    }
}
