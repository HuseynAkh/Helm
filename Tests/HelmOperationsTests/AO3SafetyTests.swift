// DRAFT: pending review, 2026-11-05
import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmTestKit
@testable import HelmOperations

final class AO3SafetyTests: XCTestCase {
    func testReplaceRetainsOriginalTrashNameAndOrigin() async throws {
        let fs = InMemoryFileSystem(), origins = InMemoryTrashOrigins()
        let source = URL(fileURLWithPath: "/a/report"), parent = URL(fileURLWithPath: "/b")
        let original = parent.appendingPathComponent("report")
        try await fs.createDirectory(at: source.deletingLastPathComponent())
        try await fs.createDirectory(at: parent)
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        try await fs.createFileExclusively(at: original, contents: Data([2]))
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [parent], policy: ConflictPolicy(defaultResolution: .replace))
        let plan = OperationPlanner.plan(.copy(sources: [source], destinationDirectory: parent), context: context)
        XCTAssertEqual(plan.steps.map(\.kind), [.copy, .verifyCopy, .trash, .move])
        let result = await OperationExecutor(fileSystem: fs, origins: origins).execute(plan)
        XCTAssertNil(result.error)
        let trash = try XCTUnwrap(result.outcomes.first { $0.step.kind == .trash })
        XCTAssertEqual(trash.step.source, original)
        XCTAssertEqual(trash.destination?.lastPathComponent, "report")
        let recorded = await origins.originalURL(forTrashed: try XCTUnwrap(trash.destination))
        XCTAssertEqual(recorded, original)
    }

    func testReplaceCannotConsumeEarlierSelectedOutput() {
        let parent = URL(fileURLWithPath: "/b")
        let context = PlanningContext(existingNames: [parent: []], defaultPolicy: ConflictPolicy(defaultResolution: .replace))
        let plan = OperationPlanner.plan(.move(sources: [URL(fileURLWithPath: "/a/x"), URL(fileURLWithPath: "/c/x")], destinationDirectory: parent), context: context)
        XCTAssertFalse(plan.isExecutable)
        XCTAssertTrue(plan.steps.isEmpty)
    }

    func testReplacementStageDoesNotExpandLongBasename() throws {
        let parent = URL(fileURLWithPath: "/b"), name = String(repeating: "x", count: 250)
        let source = URL(fileURLWithPath: "/a/" + name)
        let context = PlanningContext(existingNames: [parent: [name]], defaultPolicy: ConflictPolicy(defaultResolution: .replace))
        let plan = OperationPlanner.plan(.copy(sources: [source], destinationDirectory: parent), context: context)
        XCTAssertTrue(plan.isExecutable)
        XCTAssertLessThan(try XCTUnwrap(plan.steps.first?.destination?.lastPathComponent).utf8.count, 100)
    }

    func testEvidenceUnknownAndPartialSnapshotRefuse() async throws {
        let fs = InMemoryFileSystem(), source = URL(fileURLWithPath: "/source")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        let unrelated = FileEntry(url: URL(fileURLWithPath: "/other"))
        let plan = OperationPlan(command: .recovery, steps: [PlannedStep(kind: .trash, source: source)], context: PlanningContext(existingEntries: [unrelated.url: unrelated]))
        let evidence = await ForwardEvidence.capture(plan, fileSystem: fs)
        do { try await evidence.validate(source, fileSystem: fs); XCTFail("Unknown planning evidence must refuse") }
        catch { XCTAssertEqual(error as? OperationError, .verificationUnavailable) }
    }

    func testEvidenceUsesPathDespiteDirectorySlash() async throws {
        let fs = InMemoryFileSystem(), plain = URL(fileURLWithPath: "/folder", isDirectory: false)
        let slash = URL(fileURLWithPath: "/folder", isDirectory: true)
        try await fs.createDirectory(at: plain)
        let entry = try await fs.entry(at: plain)
        let plan = OperationPlan(command: .recovery, steps: [], context: PlanningContext(existingEntries: [plain: entry]))
        let evidence = await ForwardEvidence.capture(plan, fileSystem: fs)
        XCTAssertEqual(try evidence.precondition(for: slash).identity, entry.objectIdentity)
    }

    func testRetirementRejectsEqualSizeDestinationReplacement() async throws {
        let fs = InMemoryFileSystem(), source = URL(fileURLWithPath: "/source"), parent = URL(fileURLWithPath: "/dest")
        try await fs.createDirectory(at: parent)
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        let built = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [parent])
        let context = PlanningContext(sourceManifest: built.sourceManifest, existingNames: built.existingNames)
        let plan = OperationPlanner.plan(.move(sources: [source], destinationDirectory: parent), context: context)
        let destination = parent.appendingPathComponent("source")
        let result = await OperationExecutor(fileSystem: fs, origins: InMemoryTrashOrigins()).execute(plan) { progress in
            if progress.itemsDone == 2 && progress.currentName != nil {
                do {
                    try await fs.moveItem(at: destination, to: parent.appendingPathComponent("saved"))
                    try await fs.createFileExclusively(at: destination, contents: Data([2]))
                } catch { XCTFail("\(error)") }
            }
        }
        XCTAssertEqual(result.error, .sourceChanged(destination))
        let retained = await fs.exists(source)
        XCTAssertTrue(retained)
    }

    func testAdmissionReceivesExecutingPlanAndProgressClosureStillMatches() async {
        let plan = OperationPlan(command: .recovery, steps: [])
        let result = await OperationExecutor(fileSystem: InMemoryFileSystem(), origins: InMemoryTrashOrigins()).execute(plan, admission: { _, executing in
            XCTAssertEqual(executing, plan)
            return false
        })
        XCTAssertEqual(result.error, .invalidPlan)
    }

    func testLiveCopyAdmitsDestinationExclusively() async throws {
        let temp = try TempDirectory()
        // Canonical fixture only; it isolates mutation mapping from the ancestor walk (see OP1 FB1-11).
        let root = temp.url.resolvingSymlinksInPath()
        let source = root.appendingPathComponent("source"), destination = root.appendingPathComponent("copy")
        try Data([1, 2]).write(to: source)
        let fs = LiveFileSystem(), evidence = try await fs.mutationPrecondition(at: source)
        _ = try await fs.mutate(.copy(to: destination), source: source, requiring: evidence)
        XCTAssertEqual(try Data(contentsOf: destination), Data([1, 2]))
        try Data([7]).write(to: destination)
        do { _ = try await fs.mutate(.copy(to: destination), source: source, requiring: evidence); XCTFail("Must not overwrite") }
        catch { XCTAssertEqual(error as? FileSystemError, .collision(noMutation: true)) }
        let plan = OperationPlan(command: .recovery, steps: [PlannedStep(kind: .copy, source: source, destination: destination)])
        let result = await OperationExecutor(fileSystem: fs, origins: InMemoryTrashOrigins()).execute(plan)
        XCTAssertEqual(result.error, .conflict)
        XCTAssertEqual(try Data(contentsOf: source), Data([1, 2]))
        XCTAssertEqual(try Data(contentsOf: destination), Data([7]))
    }
}

extension AO3SafetyTests {
    func testSameVolumeMoveRefusesDifferentFakeVolume() async throws {
        let fs = InMemoryFileSystem(volumeIDs: [URL(fileURLWithPath: "/a"): "a", URL(fileURLWithPath: "/b"): "b"])
        let source = URL(fileURLWithPath: "/a/file"), destination = URL(fileURLWithPath: "/b/file")
        try await fs.createDirectory(at: source.deletingLastPathComponent())
        try await fs.createDirectory(at: destination.deletingLastPathComponent())
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        let result = await OperationExecutor(fileSystem: fs, origins: InMemoryTrashOrigins()).execute(OperationPlan(command: .recovery, steps: [PlannedStep(kind: .move, source: source, destination: destination)]))
        XCTAssertEqual(result.error, .invalidPlan)
        let sourceExists = await fs.exists(source), destinationExists = await fs.exists(destination)
        XCTAssertTrue(sourceExists); XCTAssertFalse(destinationExists)
    }
}

#if os(macOS)
extension AO3SafetyTests {
    func testNativeDirectorySlashEvidenceUsesOriginalIdentity() async throws {
        let temp = try TempDirectory(), fs = LiveFileSystem()
        let plain = URL(fileURLWithPath: temp.url.path, isDirectory: false)
        let slash = URL(fileURLWithPath: temp.url.path, isDirectory: true)
        let entry = try await fs.entry(at: plain)
        let evidence = await ForwardEvidence.capture(OperationPlan(command: .recovery, steps: [],
            context: PlanningContext(existingEntries: [plain: entry])), fileSystem: fs)
        XCTAssertEqual(try evidence.precondition(for: slash).identity, entry.objectIdentity)
        try await evidence.validate(slash, fileSystem: fs)
    }
}
#endif
