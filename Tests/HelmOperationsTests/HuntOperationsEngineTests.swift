import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmTestKit
@testable import HelmOperations

/// What a person chose is what they count and what Skip leaves out: items, not the steps that do them. A folder
/// chosen with something inside it stands for both. Aliases and links go through the engine, so Undo removes them.
final class HuntOperationsEngineTests: XCTestCase {
    private var root: URL!
    private var fs: LiveFileSystem!
    private var executor: OperationExecutor!
    private var locked: [URL] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("helm-hunt-engine-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fs = LiveFileSystem(trash: fixtureTrash(in: root.appendingPathComponent("trash")))
        executor = OperationExecutor(fileSystem: fs, origins: InMemoryTrashOrigins())
    }
    override func tearDownWithError() throws {
        for url in locked { chmod(url.path, 0o644) }
        try FileManager.default.removeItem(at: root)
    }
    private func file(_ path: String, _ text: String = "x") throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func run(_ command: Command, policy: ConflictPolicy = ConflictPolicy(),
                     decide: @escaping @Sendable (StepFailure) async -> FailureDecision = { _ in .stop }) async throws -> OperationResult {
        let scope: (sources: [URL], destinations: [URL])
        switch command {
        case .copy(let sources, let directory): scope = (sources, [directory])
        case .link(let sources, let directory, _):
            scope = ([], directory.map { [$0] } ?? Array(Set(sources.map { $0.deletingLastPathComponent() })))
        default: XCTFail("not used here"); scope = ([], [])
        }
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: scope.sources, destinations: scope.destinations, policy: policy)
        let plan = OperationPlanner.plan(command, context: context)
        XCTAssertTrue(plan.isExecutable, "\(plan.issues)")
        return await executor.execute(plan, decide: decide)
    }

    /// One replaced file is one item, named as itself, even though it takes four steps and the failed one copies into
    /// Helm's private stage. The result counts and names items, which is what the operations panel shows.
    func testAResultCountsAndNamesItemsNotSteps() async throws {
        let unreadable = try file("from/a.txt", "new")
        XCTAssertEqual(chmod(unreadable.path, 0), 0)
        locked.append(unreadable)
        let readable = try file("from/b.txt", "b")
        _ = try file("to/a.txt", "keep")
        let destination = root.appendingPathComponent("to", isDirectory: true)
        let result = try await run(.copy(sources: [unreadable, readable], destinationDirectory: destination),
                                   policy: ConflictPolicy(defaultResolution: .replace, applyToAll: true), decide: { _ in .skip })
        XCTAssertEqual(result.outcomes.count, 5, "four steps replace a.txt, one copies b.txt")
        XCTAssertEqual(result.items.count, 2)
        XCTAssertEqual(result.succeededItemCount, 1, "b.txt was copied; a.txt wasn't")
        XCTAssertEqual(result.failedItemNames, ["a.txt"])
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("a.txt"), encoding: .utf8), "keep")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("b.txt"), encoding: .utf8), "b")
        let left = try FileManager.default.contentsOfDirectory(atPath: destination.path).filter { $0.hasPrefix(".helm-stage") }
        XCTAssertEqual(left, [], "nothing of the skipped replacement is left behind")
    }

    /// Steps carry their item, so the questions and progress can name the item and count what's left of the batch.
    func testPlanItemsGroupAReplacementAndAMoveBetweenDisks() {
        let item = StepID()
        let source = URL(fileURLWithPath: "/from/a.txt"), stage = URL(fileURLWithPath: "/to/.helm-stage")
        let steps = [
            PlannedStep(kind: .copy, source: source, destination: stage, item: item),
            PlannedStep(kind: .verifyCopy, source: source, destination: stage, item: item),
            PlannedStep(kind: .trash, source: URL(fileURLWithPath: "/to/a.txt"), item: item),
            PlannedStep(kind: .move, source: stage, destination: URL(fileURLWithPath: "/to/a.txt"), item: item),
            PlannedStep(kind: .copy, source: URL(fileURLWithPath: "/from/b.txt"), destination: URL(fileURLWithPath: "/to/b.txt")),
            PlannedStep(kind: .createDirectory, destination: URL(fileURLWithPath: "/to/untitled folder"))
        ]
        let items = PlanItems(steps)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual((0..<6).map(items.name(ofStepAt:)), ["a.txt", "a.txt", "a.txt", "a.txt", "b.txt", "untitled folder"],
                       "the stage step is named as the item it installs")
        XCTAssertEqual((0..<6).map(items.remaining(afterStepAt:)), [2, 2, 2, 2, 1, 0])
    }

    /// Finder and Nautilus move a folder to the Trash, or copy it, with what's inside: an item inside a chosen folder
    /// isn't a second source, so the planner never sees the pair as overlapping.
    func testAFolderChosenWithSomethingInsideItStandsForBoth() {
        let reports = URL(fileURLWithPath: "/Users/me/Documents/Reports", isDirectory: true)
        let inside = reports.appendingPathComponent("q1.txt")
        let deeper = reports.appendingPathComponent("2026/q2.txt")
        let sibling = URL(fileURLWithPath: "/Users/me/Documents/Reports 2/q1.txt")
        XCTAssertEqual(OperationPlanner.outermost([inside, reports, deeper, sibling, reports]), [reports, sibling],
                       "a sibling whose name starts the same isn't inside")
        XCTAssertEqual(OperationPlanner.outermostSources(of: .trash(items: [reports, inside])), .trash(items: [reports]))
        let renames = Command.batchRename([RenamePair(source: reports, newName: ValidFileName("R")!),
                                           RenamePair(source: inside, newName: ValidFileName("Q")!)])
        XCTAssertEqual(OperationPlanner.outermostSources(of: renames), renames, "renaming both is renaming both")
        let plan = OperationPlanner.plan(OperationPlanner.outermostSources(of: .trash(items: [reports, inside])), context: PlanningContext())
        XCTAssertTrue(plan.isExecutable, "\(plan.issues)")
        XCTAssertEqual(plan.steps.map(\.source), [reports])
    }

    /// Make Alias and Make Symbolic Link name their output as Finder does, number it when the name is taken, and are
    /// recorded like any other change: Undo moves what they made to the Trash and leaves the original alone.
    func testLinksAreMadeByTheEngineAndUndoTakesThemAway() async throws {
        let notes = try file("docs/notes.txt", "hello")
        let folder = notes.deletingLastPathComponent()
        let first = try await run(.link(sources: [notes], destinationDirectory: nil, alias: false))
        XCTAssertNil(first.error)
        let link = folder.appendingPathComponent("notes.txt link")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), notes.path)
        let second = try await run(.link(sources: [notes], destinationDirectory: nil, alias: false))
        XCTAssertEqual(second.outcomes.first?.destination?.lastPathComponent, "notes.txt link 2")
        let alias = try await run(.link(sources: [notes], destinationDirectory: nil, alias: true))
        XCTAssertNil(alias.error)
        let aliasURL = folder.appendingPathComponent("notes.txt alias")
        XCTAssertEqual(try URL(resolvingAliasFileAt: aliasURL).resolvingSymlinksInPath().path, notes.resolvingSymlinksInPath().path)
        XCTAssertEqual(HistoryResultMapping.name(for: .link(sources: [notes], destinationDirectory: nil, alias: true)), "Make Alias")
        XCTAssertEqual(HistoryResultMapping.name(for: .link(sources: [notes], destinationDirectory: nil, alias: false)), "Make Symbolic Link")

        for result in [alias, first] {
            let stored = await executor.journal.entry(result.id)
            let entry = try XCTUnwrap(stored)
            let inverse = UndoPlanner.inverse(of: entry, recordedOrigins: [:])
            XCTAssertTrue(inverse.isExecutable, "\(inverse.issues)")
            let undone = await executor.execute(inverse)
            XCTAssertNil(undone.error)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: aliasURL.path))
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "the link went to the Trash")
        XCTAssertEqual(try String(contentsOf: notes, encoding: .utf8), "hello", "the original stays")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: folder.appendingPathComponent("notes.txt link 2").path),
                        "only what each Undo was for goes")
    }

    /// An alias dropped into another folder is made there, and a folder can't get its own alias inside itself.
    func testAnAliasDroppedIntoAFolderIsMadeThere() async throws {
        let notes = try file("docs/notes.txt")
        let target = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let result = try await run(.link(sources: [notes], destinationDirectory: target, alias: true))
        XCTAssertNil(result.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("notes.txt alias").path))
        let docs = notes.deletingLastPathComponent()
        let inside = OperationPlanner.plan(.link(sources: [docs], destinationDirectory: docs, alias: true),
                                           context: PlanningContext(existingNames: [docs: ["notes.txt"]]))
        XCTAssertFalse(inside.isExecutable)
    }
}
