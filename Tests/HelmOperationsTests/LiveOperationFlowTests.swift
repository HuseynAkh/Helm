import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmTestKit
@testable import HelmOperations

/// Whole operations on a real volume: plan, run, undo. Temp folders and a stand-in Trash only (O1-1).
final class LiveOperationFlowTests: XCTestCase {
    private var root: URL!
    private var fs: LiveFileSystem!
    private var origins: InMemoryTrashOrigins!
    private var executor: OperationExecutor!
    private var history: WindowOperationHistory!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("helm-flow-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fs = LiveFileSystem(trash: fixtureTrash(in: root.appendingPathComponent("trash")))
        origins = InMemoryTrashOrigins()
        executor = OperationExecutor(fileSystem: fs, origins: origins)
        history = WindowOperationHistory()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func file(_ name: String, _ text: String = "x") throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Runs a command the way the app does, with history.
    @discardableResult
    private func run(_ command: Command, sources: [URL], destinations: [URL], policy: ConflictPolicy = ConflictPolicy()) async throws -> OperationResult {
        let reserved = await history.beginForward(command)
        let request = try XCTUnwrap(reserved)
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: sources, destinations: destinations, policy: policy)
        let plan = OperationPlanner.plan(command, context: context)
        XCTAssertTrue(plan.isExecutable, "\(plan.issues)")
        let history = history!
        let result = await executor.execute(plan, admission: { id, plan in
            await history.bindExecution(request: request, operation: id, plan: plan)
        })
        let entry = await executor.journal.entry(result.id)
        let accepted = await history.completeForward(request: request, entry: try XCTUnwrap(entry))
        XCTAssertTrue(accepted)
        return result
    }
    @discardableResult
    private func undo() async throws -> OperationResult {
        let state = await history.snapshot()
        let top = try XCTUnwrap(state.undoEntries.last)
        var recorded: [URL: URL] = [:]
        let entry = await history.entry(for: top.operationID)
        for outcome in entry?.result?.outcomes ?? [] where outcome.step.kind == .trash && outcome.succeeded {
            if let url = outcome.destination { recorded[url] = await origins.originalURL(forTrashed: url) }
        }
        let reserved = await history.beginUndo(recordedOrigins: recorded)
        let request = try XCTUnwrap(reserved)
        let history = history!
        let result = await executor.execute(request.plan, admission: { id, plan in
            await history.bindExecution(request: request.request, operation: id, plan: plan)
        })
        await history.complete(request: request.request, outcome: result)
        return result
    }

    func testRenameThenUndoAndRedo() async throws {
        let source = try file("a.txt", "keep")
        let target = root.appendingPathComponent("b.txt")
        let command = Command.rename(RenamePair(source: source, newName: try XCTUnwrap(ValidFileName("b.txt"))))
        let renamed = try await run(command, sources: [source], destinations: [root])
        XCTAssertNil(renamed.error)
        XCTAssertTrue(exists(target)); XCTAssertFalse(exists(source))
        let undone = try await undo()
        XCTAssertNil(undone.error)
        XCTAssertTrue(exists(source)); XCTAssertFalse(exists(target))
        let redo = await history.beginRedoForward()
        let (request, again) = try XCTUnwrap(redo)
        XCTAssertEqual(again, command)
        XCTAssertFalse(exists(target))
        _ = request
    }

    func testCaseOnlyRename() async throws {
        let source = try file("note.txt")
        let result = try await run(.rename(RenamePair(source: source, newName: try XCTUnwrap(ValidFileName("NOTE.txt")))), sources: [source], destinations: [root])
        XCTAssertNil(result.error)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).contains("NOTE.txt"))
    }

    func testTrashedFolderUndoesToItsOriginalPlace() async throws {
        let inner = try file("Project/sub/a.txt", "deep")
        let folder = root.appendingPathComponent("Project")
        let trashed = try await run(.trash(items: [folder]), sources: [folder], destinations: [])
        XCTAssertNil(trashed.error)
        XCTAssertFalse(exists(folder))
        let undone = try await undo()
        XCTAssertNil(undone.error)
        XCTAssertEqual(try String(contentsOf: inner, encoding: .utf8), "deep")
    }

    func testNewFolderUndoesEvenAfterSomethingWasAddedToIt() async throws {
        let parent = try folder("parent")
        let name = try XCTUnwrap(ValidFileName("New"))
        let created = try await run(.createFolder(parent: parent, name: name), sources: [], destinations: [parent])
        XCTAssertNil(created.error)
        let new = parent.appendingPathComponent("New")
        try Data([1]).write(to: new.appendingPathComponent("added"))
        let undone = try await undo()
        XCTAssertNil(undone.error)
        XCTAssertFalse(exists(new))
        XCTAssertTrue(exists(try XCTUnwrap(undone.outcomes.first?.destination).appendingPathComponent("added")))
    }

    func testKeepBothAndReplaceAndSkip() async throws {
        let target = try folder("target")
        let existing = try file("target/a.txt", "old")
        let source = try file("a.txt", "new")
        let kept = try await run(.copy(sources: [source], destinationDirectory: target), sources: [source], destinations: [target])
        XCTAssertNil(kept.error)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("a 2.txt"), encoding: .utf8), "new")
        let replaced = try await run(.copy(sources: [source], destinationDirectory: target), sources: [source], destinations: [target],
                                     policy: ConflictPolicy(defaultResolution: .replace, applyToAll: true))
        XCTAssertNil(replaced.error)
        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "new")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path).filter { $0.hasPrefix(".helm") }, [])
        let trashCopy = try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("trash").path)
        XCTAssertEqual(trashCopy.count, 1, "The replaced item goes to the Trash, not away")
    }

    func testFolderIntoItselfIsRefusedBeforeAnythingHappens() async throws {
        let folder = try folder("Project")
        let inner = try self.folder("Project/inner")
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [folder], destinations: [inner])
        let plan = OperationPlanner.plan(.move(sources: [folder], destinationDirectory: inner), context: context)
        XCTAssertFalse(plan.isExecutable)
    }
}
