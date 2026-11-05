// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import Foundation
import HelmCore
@testable import HelmFileSystem
@testable import HelmOperations

final class F7RegressionTests: XCTestCase {
    private func fixture(caseSensitive: Bool = true) async throws -> InMemoryFileSystem {
        let fs = InMemoryFileSystem(caseSensitive: caseSensitive)
        try await fs.createDirectory(at: URL(fileURLWithPath: "/src"))
        try await fs.createDirectory(at: URL(fileURLWithPath: "/dest"))
        try await fs.createFileExclusively(at: URL(fileURLWithPath: "/src/report.txt"), contents: Data([1]))
        return fs
    }
    func testForwardTrashRejectsSubstitutedSource() async throws { try await checkSource(moving: false) }
    func testForwardMoveRejectsSubstitutedSource() async throws { try await checkSource(moving: true) }
    private func checkSource(moving: Bool) async throws {
        let fs = try await fixture()
        let source = URL(fileURLWithPath: "/src/report.txt"), parent = URL(fileURLWithPath: "/dest")
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [parent])
        let command: Command = moving ? .move(sources: [source], destinationDirectory: parent) : .trash(items: [source])
        let result = await OperationExecutor(fileSystem: fs).execute(OperationPlanner.plan(command, context: context)) { progress in
            if progress.itemsDone == 0 && progress.currentName != nil {
                do {
                    try await fs.moveItem(at: source, to: URL(fileURLWithPath: "/saved"))
                    try await fs.createFileExclusively(at: source, contents: Data([7, 8]))
                } catch { XCTFail("Fixture substitution failed: \(error)") }
            }
        }
        XCTAssertEqual(result.error, .sourceChanged(source))
        let replacement = try await fs.entry(at: source)
        XCTAssertEqual(replacement.size, 2)
    }
    func testBackupTrashRejectsSubstitution() async throws { try await checkArtifact(index: 4) }
    func testStageInstallationRejectsSubstitution() async throws { try await checkArtifact(index: 3) }
    func testReplacementTargetRejectsSubstitution() async throws { try await checkArtifact(index: 2) }
    private func checkArtifact(index: Int) async throws {
        let fs = try await fixture()
        let source = URL(fileURLWithPath: "/src/report.txt"), parent = URL(fileURLWithPath: "/dest")
        try await fs.createFileExclusively(at: parent.appendingPathComponent("report.txt"), contents: Data([2]))
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [parent], policy: ConflictPolicy(defaultResolution: .replace))
        let plan = OperationPlanner.plan(.copy(sources: [source], destinationDirectory: parent), context: context)
        let artifact = try XCTUnwrap(plan.steps[index].source)
        let result = await OperationExecutor(fileSystem: fs).execute(plan) { progress in
            if progress.itemsDone == index && progress.currentName != nil {
                do {
                    try await fs.moveItem(at: artifact, to: URL(fileURLWithPath: "/saved"))
                    try await fs.createFileExclusively(at: artifact, contents: Data([7, 8, 9]))
                } catch { XCTFail("Fixture substitution failed: \(error)") }
            }
        }
        XCTAssertEqual(result.error, .sourceChanged(artifact))
        XCTAssertEqual(result.succeededCount, index)
        let retained = try await fs.entry(at: artifact)
        XCTAssertEqual(retained.size, 3)
    }
    func testReplaceUndoRestoresOriginalCaseAndBytes() async throws {
        let fs = try await fixture(caseSensitive: false)
        let source = URL(fileURLWithPath: "/src/report.txt"), parent = URL(fileURLWithPath: "/dest")
        let original = parent.appendingPathComponent("REPORT.TXT")
        try await fs.createFileExclusively(at: original, contents: Data([4, 5]))
        let origins = InMemoryTrashOrigins(), executor = OperationExecutor(fileSystem: fs, origins: origins)
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [parent], policy: ConflictPolicy(defaultResolution: .replace))
        let result = await executor.execute(OperationPlanner.plan(.copy(sources: [source], destinationDirectory: parent), context: context))
        XCTAssertNil(result.error)
        let stored = await executor.journal.entry(result.id)
        let inverse = await UndoPlanner.inverse(of: try XCTUnwrap(stored), origins: origins)
        let undone = await executor.execute(inverse)
        XCTAssertNil(undone.error)
        let names = try await fs.childNames(of: parent)
        XCTAssertEqual(names, ["REPORT.TXT"])
        let entry = try await fs.entry(at: original)
        XCTAssertEqual(entry.size, 2)
        let bytes = try await fs.storedContents(at: original)
        XCTAssertEqual(bytes, Data([4, 5]))
    }
    func testCutCompletionVisitsAreLinear() {
        let sources = (0..<100_000).map { URL(fileURLWithPath: "/src/\($0)") }
        let outcomes = sources.enumerated().map { index, source in
            ItemOutcome(step: PlannedStep(kind: .move, source: source), destination: nil,
                        result: index.isMultiple(of: 5) ? .failure(.notAttempted) : .success(nil))
        } + [ItemOutcome(step: PlannedStep(kind: .trash, source: URL(fileURLWithPath: "/stage")), destination: nil, result: .success(nil))]
        let result = OperationResult(id: OperationID(), command: .move(sources: sources, destinationDirectory: URL(fileURLWithPath: "/dest")), outcomes: outcomes)
        var visits = 0
        let completed = result.completedMoveSources { visits += 1 }
        XCTAssertEqual(completed, Set(sources.enumerated().filter { !$0.offset.isMultiple(of: 5) }.map(\.element)))
        XCTAssertLessThanOrEqual(visits, sources.count + outcomes.count)
    }
}

extension F7RegressionTests {
    func testMissingArtifactMetadataRefusesDependentMutation() async throws {
        let fs = InMemoryFileSystem(), source = URL(fileURLWithPath: "/source"), stage = URL(fileURLWithPath: "/stage")
        try await fs.createFileExclusively(at: stage, contents: Data([1]))
        var evidence = await ForwardEvidence.capture(OperationPlan(command: .recovery, steps: []), fileSystem: fs)
        evidence.completed(PlannedStep(kind: .copy, source: source, destination: stage), destination: stage, entry: nil)
        do { try await evidence.validate(stage, fileSystem: fs); XCTFail("Missing ownership must refuse") }
        catch { XCTAssertEqual(error as? OperationError, .verificationUnavailable) }
    }
    func testVerificationCannotAdoptChangedArtifact() async throws {
        let fs = InMemoryFileSystem(), stage = URL(fileURLWithPath: "/stage")
        try await fs.createFileExclusively(at: stage, contents: Data([1]))
        var evidence = await ForwardEvidence.capture(OperationPlan(command: .recovery, steps: []), fileSystem: fs)
        evidence.record(stage, entry: try await fs.entry(at: stage))
        try await fs.moveItem(at: stage, to: URL(fileURLWithPath: "/saved"))
        try await fs.createFileExclusively(at: stage, contents: Data([2, 3]))
        evidence.completed(PlannedStep(kind: .verifyCopy, destination: stage), destination: stage, entry: try await fs.entry(at: stage))
        do { try await evidence.validate(stage, fileSystem: fs); XCTFail("Verification must not replace ownership") }
        catch { XCTAssertEqual(error as? OperationError, .sourceChanged(stage)) }
    }
    func testForwardKindMismatchWithEqualTokenRefuses() async throws {
        let fs = InMemoryFileSystem(), source = URL(fileURLWithPath: "/file")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        let entry = try await fs.entry(at: source)
        let context = PlanningContext(sourceManifest: [SourceEntry(source: source, relativePath: "", kind: .alias, size: entry.size, changeToken: entry.changeToken)])
        let result = await OperationExecutor(fileSystem: fs).execute(OperationPlanner.plan(.trash(items: [source]), context: context))
        XCTAssertEqual(result.error, .sourceChanged(source))
    }
    func testForwardDirectoryMoveAndTrashRemainAvailable() async throws {
        for moving in [false, true] {
            let fs = InMemoryFileSystem(), source = URL(fileURLWithPath: "/tree"), parent = URL(fileURLWithPath: "/dest")
            try await fs.createDirectory(at: source)
            try await fs.createDirectory(at: parent)
            try await fs.createFileExclusively(at: source.appendingPathComponent("child"), contents: Data([1]))
            let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [parent])
            let command: Command = moving ? .move(sources: [source], destinationDirectory: parent) : .trash(items: [source])
            let result = await OperationExecutor(fileSystem: fs).execute(OperationPlanner.plan(command, context: context))
            XCTAssertNil(result.error)
            XCTAssertEqual(result.succeededCount, 1)
        }
    }
    func testReplacementTargetChangedAfterPlanningIsRefused() async throws {
        let fs = try await fixture()
        let source = URL(fileURLWithPath: "/src/report.txt"), parent = URL(fileURLWithPath: "/dest")
        let target = parent.appendingPathComponent("report.txt")
        try await fs.createFileExclusively(at: target, contents: Data([2]))
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [parent], policy: ConflictPolicy(defaultResolution: .replace))
        let plan = OperationPlanner.plan(.copy(sources: [source], destinationDirectory: parent), context: context)
        try await fs.moveItem(at: target, to: URL(fileURLWithPath: "/saved"))
        try await fs.createFileExclusively(at: target, contents: Data([3, 4]))
        let result = await OperationExecutor(fileSystem: fs).execute(plan)
        XCTAssertEqual(result.error, .sourceChanged(target))
        XCTAssertEqual(result.succeededCount, 2)
    }
    func testNonMoveCutCompletionIsEmpty() {
        let source = URL(fileURLWithPath: "/source")
        let result = OperationResult(id: OperationID(), command: .trash(items: [source]), outcomes: [ItemOutcome(step: PlannedStep(kind: .trash, source: source), destination: nil, result: .success(nil))])
        var visits = 0
        XCTAssertTrue(result.completedMoveSources { visits += 1 }.isEmpty)
        XCTAssertEqual(visits, 0)
    }
}

extension F7RegressionTests {
    func testReplacementOfSymlinkPreservesLeafSemantics() async throws {
        let fs = try await fixture()
        let source = URL(fileURLWithPath: "/src/report.txt"), parent = URL(fileURLWithPath: "/dest")
        let target = parent.appendingPathComponent("report.txt")
        try await fs.createSymbolicLink(at: target, destination: URL(fileURLWithPath: "/src"))
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [parent], policy: ConflictPolicy(defaultResolution: .replace))
        let result = await OperationExecutor(fileSystem: fs).execute(OperationPlanner.plan(.copy(sources: [source], destinationDirectory: parent), context: context))
        XCTAssertNil(result.error)
        let original = try await fs.entry(at: source)
        XCTAssertEqual(original.size, 1)
        let installed = try await fs.entry(at: target)
        XCTAssertEqual(installed.kind, .regular)
    }
    func testNormalizedReplacementUndoRetainsOriginalScalars() async throws {
        let fs = InMemoryFileSystem(caseSensitive: false)
        let parent = URL(fileURLWithPath: "/dest"), sourceParent = URL(fileURLWithPath: "/src")
        try await fs.createDirectory(at: parent)
        try await fs.createDirectory(at: sourceParent)
        let source = sourceParent.appendingPathComponent("café.txt")
        let originalName = "cafe\u{301}.txt"
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        try await fs.createFileExclusively(at: parent.appendingPathComponent(originalName), contents: Data([9, 8]))
        let origins = InMemoryTrashOrigins(), executor = OperationExecutor(fileSystem: fs, origins: origins)
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [parent], policy: ConflictPolicy(defaultResolution: .replace))
        let result = await executor.execute(OperationPlanner.plan(.copy(sources: [source], destinationDirectory: parent), context: context))
        XCTAssertNil(result.error)
        let stored = await executor.journal.entry(result.id)
        let undo = await UndoPlanner.inverse(of: try XCTUnwrap(stored), origins: origins)
        let undone = await executor.execute(undo)
        XCTAssertNil(undone.error)
        let names = try await fs.childNames(of: parent)
        XCTAssertEqual(names.count, 1)
        XCTAssertEqual(Array(try XCTUnwrap(names.first).utf8), Array(originalName.utf8))
    }
}

extension F7RegressionTests {
    func testMissingCopiedStageMetadataMarksReconciliationAndRetainsSuccess() async throws {
        let fs = try await fixture()
        let source = URL(fileURLWithPath: "/src/report.txt"), parent = URL(fileURLWithPath: "/dest")
        try await fs.createFileExclusively(at: parent.appendingPathComponent("report.txt"), contents: Data([2]))
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [parent], policy: ConflictPolicy(defaultResolution: .replace))
        let plan = OperationPlanner.plan(.copy(sources: [source], destinationDirectory: parent), context: context)
        let result = await OperationExecutor(fileSystem: fs, copier: F7UnreadableOutputCopier(fileSystem: fs)).execute(plan)
        XCTAssertEqual(result.error, .verificationUnavailable)
        XCTAssertEqual(result.succeededCount, 1)
        XCTAssertTrue(result.outcomes[1].requiresReconciliation)
        let stage = try XCTUnwrap(plan.steps.first?.destination)
        await fs.setFailure(nil, at: stage)
        let retained = try await fs.entry(at: stage)
        XCTAssertEqual(retained.size, 1)
    }
}
private struct F7UnreadableOutputCopier: FileCopier {
    let fileSystem: InMemoryFileSystem
    func copy(from source: URL, to destination: URL) async throws {
        try await fileSystem.copyItem(at: source, to: destination)
        await fileSystem.setFailure(.permissionDenied, at: destination)
    }
}
