// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import Foundation
import HelmCore
import HelmFileSystem
@testable import HelmOperations

final class RecoveryTests: XCTestCase {
    func testUnknownTrashOriginAndNilTrashURLAreNotRestorable() {
        let source = URL(fileURLWithPath: "/original"), trash = URL(fileURLWithPath: "/.Trash/original")
        for destination: URL? in [nil, trash] {
            let step = PlannedStep(kind: .trash, source: source)
            let plan = OperationPlan(command: .trash(items: [source]), steps: [step])
            let id = OperationID()
            let outcome = ItemOutcome(step: step, destination: destination, result: .success(ChangeToken(modificationDate: .distantPast, size: 1, childCount: nil)))
            let entry = JournalEntry(id: id, plan: plan, result: OperationResult(id: id, command: plan.command, outcomes: [outcome]))
            XCTAssertFalse(UndoPlanner.inverse(of: entry, recordedOrigins: [:]).isExecutable)
            if let destination {
                XCTAssertTrue(UndoPlanner.inverse(of: entry, recordedOrigins: [destination: source]).isExecutable)
                XCTAssertFalse(UndoPlanner.inverse(of: entry, recordedOrigins: [destination: trash]).isExecutable)
            }
        }
    }
    func testUndoRefusesChangedOutput() async throws {
        let fs = InMemoryFileSystem(), source = URL(fileURLWithPath: "/x"), parent = URL(fileURLWithPath: "/target")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        try await fs.createDirectory(at: parent)
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [parent])
        let executor = OperationExecutor(fileSystem: fs)
        let result = await executor.execute(OperationPlanner.plan(.copy(sources: [source], destinationDirectory: parent), context: context))
        let stored = await executor.journal.entry(result.id)
        let inverse = UndoPlanner.inverse(of: try XCTUnwrap(stored), recordedOrigins: [:])
        let copied = parent.appendingPathComponent("x")
        _ = try await fs.trashItem(at: copied)
        try await fs.createFileExclusively(at: copied, contents: Data([2, 3]))
        let undo = await executor.execute(inverse)
        XCTAssertEqual(undo.error, .sourceChanged(copied))
        let entry = try await fs.entry(at: copied); XCTAssertEqual(entry.size, 2)
    }
    func testSnapshotBuilderDoesNotTraverseSymlinksAndVerifierChecksTreeShape() async throws {
        let fs = InMemoryFileSystem(), directory = URL(fileURLWithPath: "/dir"), destination = URL(fileURLWithPath: "/copy")
        try await fs.createDirectory(at: directory)
        try await fs.createSymbolicLink(at: directory.appendingPathComponent("loop"), destination: directory)
        try await fs.createFileExclusively(at: directory.appendingPathComponent("data"), contents: Data([1]))
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [directory], destinations: [URL(fileURLWithPath: "/")])
        XCTAssertEqual(context.sourceManifest.count, 3)
        try await fs.copyItem(at: directory, to: destination)
        try await TreeCopyVerifier(fileSystem: fs).verify(source: directory, destination: destination)
        try await fs.createFileExclusively(at: destination.appendingPathComponent("extra"), contents: Data())
        do { try await TreeCopyVerifier(fileSystem: fs).verify(source: directory, destination: destination); XCTFail("Must reject extra child") }
        catch { XCTAssertEqual(error as? OperationError, .verificationFailed) }
    }
    func testSymlinkAncestorCannotRedirectMutation() async throws {
        let fs = InMemoryFileSystem(), root = URL(fileURLWithPath: "/real"), link = URL(fileURLWithPath: "/link")
        try await fs.createDirectory(at: root); try await fs.createSymbolicLink(at: link, destination: root)
        let executor = OperationExecutor(fileSystem: fs)
        let result = await executor.execute(OperationPlan(command: .recovery, steps: [PlannedStep(kind: .createFile, destination: link.appendingPathComponent("new"))]))
        XCTAssertEqual(result.error, .invalidPlan)
        let names = try await fs.childNames(of: root); XCTAssertTrue(names.isEmpty)
    }
    func testReentrantExecutionIsRejected() async throws {
        let fs = InMemoryFileSystem(), executor = OperationExecutor(fileSystem: fs)
        let plan = OperationPlan(command: .recovery, steps: [PlannedStep(kind: .createFile, destination: URL(fileURLWithPath: "/new"))])
        let results = ResultCollector()
        let result = await executor.execute(plan) { progress in
            if progress.currentName != nil { await results.append(await executor.execute(plan)) }
        }
        XCTAssertNil(result.error)
        let reentrant = await results.values(); XCTAssertEqual(reentrant.first?.error, .busy)
    }
    func testExclusiveRaceRetriesAndRecordsActualName() async throws {
        let fs = InMemoryFileSystem(), source = URL(fileURLWithPath: "/x"), destination = URL(fileURLWithPath: "/target")
        try await fs.createFileExclusively(at: source, contents: Data([1, 2]))
        try await fs.createDirectory(at: destination)
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [destination])
        let copier = RacingCopier(fileSystem: fs)
        let result = await OperationExecutor(fileSystem: fs, copier: copier).execute(OperationPlanner.plan(.copy(sources: [source], destinationDirectory: destination), context: context))
        XCTAssertNil(result.error); XCTAssertEqual(result.outcomes.first?.destination?.lastPathComponent, "x 2")
        let other = try await fs.entry(at: destination.appendingPathComponent("x")); XCTAssertEqual(other.size, 1)
    }
    func testVirtualCreationAndSelectedTargetOverlap() throws {
        let name = try XCTUnwrap(ValidFileName("New Folder"))
        XCTAssertFalse(OperationPlanner.creation(name: name, in: .recent, folder: true, context: PlanningContext()).isExecutable)
        let a = URL(fileURLWithPath: "/a/x"), b = URL(fileURLWithPath: "/b/x"), parent = URL(fileURLWithPath: "/b")
        let context = PlanningContext(existingNames: [parent: ["x"]], defaultPolicy: ConflictPolicy(defaultResolution: .replace))
        XCTAssertFalse(OperationPlanner.plan(.copy(sources: [a, b], destinationDirectory: parent), context: context).isExecutable)
    }
    func testPendingAndCompletedJournalLifecycle() async {
        let journal = OperationJournal(), plan = OperationPlan(command: .recovery, steps: [])
        let id = await journal.begin(plan)
        let pending = await journal.entry(id)
        XCTAssertNotNil(pending); XCTAssertNil(pending?.result)
        let result = OperationResult(id: id, command: .recovery, outcomes: [])
        let completed = await journal.complete(result), repeated = await journal.complete(result)
        XCTAssertTrue(completed); XCTAssertFalse(repeated)
        let all = await journal.allEntries(); XCTAssertEqual(all.count, 1)
        XCTAssertFalse(UndoPlanner.inverse(of: JournalEntry(id: id, plan: plan), recordedOrigins: [:]).isExecutable)
    }
}
private actor ResultCollector {
    private var results: [OperationResult] = []
    func append(_ result: OperationResult) { results.append(result) }
    func values() -> [OperationResult] { results }
}
private actor RacingCopier: FileCopier {
    let fileSystem: InMemoryFileSystem
    var first: Bool = true
    init(fileSystem: InMemoryFileSystem) { self.fileSystem = fileSystem }
    func copy(from source: URL, to destination: URL) async throws {
        if first {
            first = false
            try await fileSystem.createFileExclusively(at: destination, contents: Data([9]))
            throw ExclusiveDestinationConflict()
        }
        try await fileSystem.copyItem(at: source, to: destination)
    }
}
