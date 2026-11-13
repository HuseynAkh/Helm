import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmOperations

/// One applied plan is one Undo, shown here on the engine itself: commands planned against the disk, run by the real
/// executor and journal, and recorded by a window's history under one group, as the coordinator does. Each command is
/// named after the group; Undo walks back through them one at a time; a failed Undo leaves the rest in place; an
/// entry left unsure ends the group there; and nothing of the group that was undone can be redone.
final class HistoryGroupFlowTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home/flow", isDirectory: true)
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    private var archive: URL { home.appendingPathComponent("Archive", isDirectory: true) }
    private var sorted: URL { documents.appendingPathComponent("Sorted", isDirectory: true) }
    private let group = HistoryGroup(name: "Organize “Documents”")
    private var fileSystem: InMemoryFileSystem!
    private var origins: InMemoryTrashOrigins!
    private var executor: OperationExecutor!
    private var history: WindowOperationHistory!

    override func setUp() async throws {
        try await super.setUp()
        let memory = InMemoryFileSystem()
        for folder in [URL(fileURLWithPath: "/home"), home, documents, archive] { try await memory.createDirectory(at: folder) }
        for name in ["a.txt", "b.txt", "c.txt", "d.txt", "plain.txt"] {
            try await memory.createFileExclusively(at: documents.appendingPathComponent(name), contents: Data(name.utf8))
        }
        let origins = InMemoryTrashOrigins()
        fileSystem = memory
        self.origins = origins
        executor = OperationExecutor(fileSystem: memory, origins: origins)
        history = WindowOperationHistory()
    }
    override func tearDown() async throws {
        fileSystem = nil; origins = nil; executor = nil; history = nil
        try await super.tearDown()
    }

    // MARK: The coordinator's way of running and undoing a command

    /// Reserves the history, plans against the disk as it is now, runs through the executor bound to the reservation,
    /// and records the journal's entry: what the coordinator does for one command.
    @discardableResult
    private func run(_ command: Command, group: HistoryGroup?) async throws -> OperationResult {
        let history = history!
        let reserved = await history.beginForward(command, group: group)
        let request = try XCTUnwrap(reserved, "the history refused the command")
        let (sources, destinations) = Self.scope(of: command)
        let context = try await PlanningContextBuilder(fileSystem: fileSystem).build(sources: sources, destinations: destinations)
        let plan = OperationPlanner.plan(command, context: context)
        XCTAssertTrue(plan.isExecutable)
        XCTAssertFalse(plan.steps.isEmpty)
        let result = await executor.execute(plan, admission: { id, plan in
            await history.bindExecution(request: request, operation: id, plan: plan)
        })
        let entry = await executor.journal.entry(result.id)
        let recorded = await history.completeForward(request: request, entry: try XCTUnwrap(entry))
        XCTAssertTrue(recorded)
        return result
    }
    /// Undoes the latest entry, one step, as the coordinator does: the Trash's records say where trashed items go back.
    /// Answers whether that Undo succeeded.
    @discardableResult
    private func undoOne() async -> Bool {
        let history = history!
        guard let top = await history.snapshot().undoEntries.last else { return false }
        var recorded: [URL: URL] = [:]
        for outcome in await history.entry(for: top.operationID)?.result?.outcomes ?? [] where outcome.step.kind == .trash && outcome.succeeded {
            if let place = outcome.destination { recorded[place] = await origins.originalURL(forTrashed: place) }
        }
        guard let request = await history.beginUndo(recordedOrigins: recorded) else { return false }
        let result = await executor.execute(request.plan, admission: { id, plan in
            await history.bindExecution(request: request.request, operation: id, plan: plan)
        })
        let completed = await history.complete(request: request.request, outcome: result)
        XCTAssertTrue(completed)
        return await history.snapshot().lastOutcome == .succeeded
    }
    /// Undoes the latest entry and, while it was one of a group and each Undo succeeds, the next one down for as long as
    /// it belongs to the same group: the window's one Undo. Answers how many entries it undid and whether all went well.
    private func undoGroup() async -> (undone: Int, succeeded: Bool) {
        var undone = 0
        while true {
            let top = await history.snapshot().undoEntries.last
            guard await undoOne() else { return (undone, false) }
            undone += 1
            guard let id = top?.group?.id, await history.snapshot().undoEntries.last?.group?.id == id else { return (undone, true) }
        }
    }
    private static func scope(of command: Command) -> (sources: [URL], destinations: [URL]) {
        switch command {
        case .copy(let sources, let directory), .move(let sources, let directory): return (sources, [directory])
        case .trash(let items): return (items, [])
        case .rename(let pair): return ([pair.source], [pair.source.deletingLastPathComponent()])
        case .batchRename(let pairs): return (pairs.map(\.source), Array(Set(pairs.map { $0.source.deletingLastPathComponent() })))
        case .createFolder(let parent, _): return ([], [parent])
        default: return ([], [])
        }
    }

    // MARK: The plan

    private func name(_ text: String) throws -> ValidFileName { try XCTUnwrap(ValidFileName(text)) }
    private func file(_ name: String, in folder: URL) -> URL { folder.appendingPathComponent(name) }
    private func exists(_ name: String, in folder: URL) async -> Bool { await fileSystem.exists(file(name, in: folder)) }

    /// plain.txt moves to Archive on its own first. Then five commands run under the group, as an applied plan runs
    /// them: a new folder, a rename, a move into the new folder, a copy to Archive, and a move to the Trash.
    private func applyPlan() async throws -> [Command] {
        try await run(.move(sources: [file("plain.txt", in: documents)], destinationDirectory: archive), group: nil)
        let commands: [Command] = [
            .createFolder(parent: documents, name: try name("Sorted")),
            .rename(RenamePair(source: file("a.txt", in: documents), newName: try name("alpha.txt"))),
            .move(sources: [file("alpha.txt", in: documents), file("b.txt", in: documents)], destinationDirectory: sorted),
            .copy(sources: [file("c.txt", in: documents)], destinationDirectory: archive),
            .trash(items: [file("d.txt", in: documents)])
        ]
        for command in commands {
            let result = try await run(command, group: group)
            XCTAssertNil(result.error, "\(command) failed")
        }
        return commands
    }
    /// What the disk looks like at each point of the walk back, from the plan applied (0) to every command undone (5).
    private func assertDisk(undone: Int, file line: UInt = #line) async {
        let inDocuments = await exists("d.txt", in: documents)
        XCTAssertEqual(inDocuments, undone >= 1, "d.txt is back from the Trash only once the Trash is undone", line: line)
        let copied = await exists("c.txt", in: archive)
        XCTAssertEqual(copied, undone < 2, "the copy in Archive is gone once the copy is undone", line: line)
        let original = await exists("c.txt", in: documents)
        XCTAssertTrue(original, "the copy's original never moves", line: line)
        let moved = await exists("alpha.txt", in: sorted)
        let movedB = await exists("b.txt", in: sorted)
        XCTAssertEqual(moved, undone < 3, line: line)
        XCTAssertEqual(movedB, undone < 3, line: line)
        let backB = await exists("b.txt", in: documents)
        XCTAssertEqual(backB, undone >= 3, line: line)
        let renamed = await exists("alpha.txt", in: documents)
        XCTAssertEqual(renamed, undone == 3, "alpha.txt is back in Documents until the rename is undone", line: line)
        let named = await exists("a.txt", in: documents)
        XCTAssertEqual(named, undone >= 4, line: line)
        let folder = await fileSystem.exists(sorted)
        XCTAssertEqual(folder, undone < 5, "Sorted goes to the Trash once the new folder is undone", line: line)
        let plain = await exists("plain.txt", in: archive)
        XCTAssertTrue(plain, "the change made before the group is never undone with it", line: line)
    }

    // MARK: Tests

    func testEachCommandOfTheGroupIsNamedAfterIt() async throws {
        _ = try await applyPlan()
        await assertDisk(undone: 0)
        let state = await history.snapshot()
        XCTAssertEqual(state.undoEntries.map(\.name), ["Move"] + Array(repeating: "Organize “Documents”", count: 5))
        XCTAssertEqual(state.undoEntries.map(\.group), [nil, group, group, group, group, group])
        XCTAssertEqual(state.undoAvailability, .available("Organize “Documents”"))
        // Each entry is the journal's record of its own command, as the executor ran it.
        let journal = await executor.journal.allEntries()
        XCTAssertEqual(journal.count, 6)
        for entry in state.undoEntries {
            let recorded = await history.entry(for: entry.operationID)
            XCTAssertEqual(recorded?.result?.error, nil)
            XCTAssertTrue(journal.contains { $0.id == entry.operationID })
        }
    }

    func testUndoAfterUndoWalksBackThroughTheGroup() async throws {
        _ = try await applyPlan()
        for step in 1...5 {
            let undone = await undoOne()
            XCTAssertTrue(undone, "Undo \(step) failed")
            await assertDisk(undone: step)
            let state = await history.snapshot()
            XCTAssertEqual(state.undoEntries.count, 6 - step)
            XCTAssertTrue(state.redoEntries.isEmpty, "an undone command of the group reached the redo stack")
            XCTAssertNil(state.reconciliation)
            XCTAssertEqual(state.undoAvailability, .available(step < 5 ? "Organize “Documents”" : "Move"))
        }
        // The change made before the group is undone on its own, afterwards, and can be redone as ever.
        let plain = await undoOne()
        XCTAssertTrue(plain)
        let back = await exists("plain.txt", in: documents)
        XCTAssertTrue(back)
        let state = await history.snapshot()
        XCTAssertEqual(state.redoEntries.map(\.name), ["Move"])
    }

    func testOneUndoOfTheGroupUndoesAllFiveAndNothingBelow() async throws {
        _ = try await applyPlan()
        let walked = await undoGroup()
        XCTAssertEqual(walked.undone, 5)
        XCTAssertTrue(walked.succeeded)
        await assertDisk(undone: 5)
        let state = await history.snapshot()
        XCTAssertEqual(state.undoEntries.map(\.name), ["Move"])
        XCTAssertEqual(state.undoAvailability, .available("Move"))
        // Nothing of the group can be redone, by the menu or by the history itself.
        XCTAssertTrue(state.redoEntries.isEmpty)
        XCTAssertEqual(state.redoAvailability, .empty)
        let redo = await history.beginRedoForward()
        XCTAssertNil(redo)
        let asked = await history.beginRedo()
        XCTAssertEqual(asked, .empty)
        // The disk didn't change by asking.
        await assertDisk(undone: 5)
    }

    func testAFailedUndoLeavesTheRestOfTheGroupInPlace() async throws {
        _ = try await applyPlan()
        // Undo of the copy reads the copy in Archive first; that read now fails, so it can't be undone.
        let copy = file("c.txt", in: archive)
        await fileSystem.setFailure(.permissionDenied, at: copy)
        let walked = await undoGroup()
        XCTAssertEqual(walked.undone, 1, "the Trash was undone, then the copy's Undo failed")
        XCTAssertFalse(walked.succeeded)
        await fileSystem.setFailure(nil, at: copy)
        await assertDisk(undone: 1)
        let state = await history.snapshot()
        XCTAssertNil(state.reconciliation, "a refused Undo changed nothing, so nothing is unsure")
        XCTAssertEqual(state.undoEntries.count, 5, "the copy and the three below it are still there, with the plain move")
        XCTAssertEqual(state.undoEntries.map(\.group), [nil, group, group, group, group])
        XCTAssertEqual(state.undoAvailability, .available("Organize “Documents”"))
        XCTAssertTrue(state.redoEntries.isEmpty)

        // Asked again, the rest of the group is undone from where it stopped, and nothing below it.
        let rest = await undoGroup()
        XCTAssertEqual(rest.undone, 4)
        XCTAssertTrue(rest.succeeded)
        await assertDisk(undone: 5)
        let after = await history.snapshot()
        XCTAssertEqual(after.undoEntries.map(\.name), ["Move"])
        XCTAssertTrue(after.redoEntries.isEmpty)
    }

    func testAnUndoLeftUnsureEndsTheGroupThere() async throws {
        _ = try await applyPlan()
        // Undo of the move puts b.txt back in Documents. The disk refuses that partway through the change itself, so
        // the Undo may have done part of its work.
        await fileSystem.setFailure(.other("The disk went away."), at: file("b.txt", in: documents))
        let walked = await undoGroup()
        XCTAssertEqual(walked.undone, 2, "the Trash and the copy were undone, then the move was left unsure")
        XCTAssertFalse(walked.succeeded)
        await fileSystem.setFailure(nil, at: file("b.txt", in: documents))
        let unsure = await history.snapshot()
        XCTAssertNotNil(unsure.reconciliation)
        XCTAssertEqual(unsure.undoAvailability, .reconciliationRequired)
        let refused = await history.beginUndo(recordedOrigins: [:])
        XCTAssertNil(refused, "nothing else is undone until the unsure change is acknowledged")
        let still = await exists("b.txt", in: sorted)
        XCTAssertTrue(still, "the walk stopped at the unsure entry")

        // Acknowledged, the unsure entry is let go. It can't be redone, and the group's entries below it stay.
        let acknowledged = await history.acknowledgeReconciliation()
        XCTAssertTrue(acknowledged)
        let state = await history.snapshot()
        XCTAssertNil(state.reconciliation)
        XCTAssertEqual(state.undoEntries.map(\.name), ["Move", "Organize “Documents”", "Organize “Documents”"])
        XCTAssertEqual(state.undoEntries.map(\.group), [nil, group, group])
        XCTAssertTrue(state.redoEntries.isEmpty)
        let redo = await history.beginRedoForward()
        XCTAssertNil(redo)
        let renamed = await exists("alpha.txt", in: documents)
        XCTAssertFalse(renamed, "the rename below the unsure entry wasn't undone")
        let folder = await fileSystem.exists(sorted)
        XCTAssertTrue(folder, "the new folder below the unsure entry wasn't undone")
    }

    func testACommandLeftUnsureWhileApplyingEndsTheGroupThere() async throws {
        try await run(.move(sources: [file("plain.txt", in: documents)], destinationDirectory: archive), group: nil)
        try await run(.createFolder(parent: documents, name: try name("Sorted")), group: group)
        try await run(.rename(RenamePair(source: file("a.txt", in: documents), newName: try name("alpha.txt"))), group: group)
        // The move's change fails partway through for alpha.txt, so it may be partly done, and the move stops there.
        await fileSystem.setFailure(.other("The disk went away."), at: file("alpha.txt", in: sorted))
        let move = try await run(.move(sources: [file("alpha.txt", in: documents), file("b.txt", in: documents)],
                                       destinationDirectory: sorted), group: group)
        XCTAssertEqual(move.outcomes.map(\.requiresReconciliation), [true, false])
        XCTAssertEqual(move.outcomes.last?.result, .failure(.notAttempted))
        await fileSystem.setFailure(nil, at: file("alpha.txt", in: sorted))
        let unsure = await history.snapshot()
        XCTAssertNotNil(unsure.reconciliation)
        XCTAssertEqual(unsure.undoEntries.last?.group, group, "the unsure command is recorded under the group")
        // Nothing more of the plan can start, and nothing can be undone, until the person has acknowledged it.
        let next = await history.beginForward(.trash(items: [file("d.txt", in: documents)]), group: group)
        XCTAssertNil(next)
        let early = await history.beginUndo(recordedOrigins: [:])
        XCTAssertNil(early)

        let acknowledged = await history.acknowledgeReconciliation()
        XCTAssertTrue(acknowledged)
        let state = await history.snapshot()
        XCTAssertEqual(state.undoEntries.map(\.name), ["Move", "Organize “Documents”", "Organize “Documents”"],
                       "the unsure move is let go; the new folder and the rename stay")
        XCTAssertEqual(state.undoEntries.map(\.group), [nil, group, group])
        XCTAssertTrue(state.redoEntries.isEmpty)
        let redo = await history.beginRedoForward()
        XCTAssertNil(redo, "the unsure move can't be redone")

        // One Undo of what is left of the group undoes the rename and the new folder, and stops at the plain move.
        let walked = await undoGroup()
        XCTAssertEqual(walked.undone, 2)
        XCTAssertTrue(walked.succeeded)
        let named = await exists("a.txt", in: documents)
        XCTAssertTrue(named)
        let folder = await fileSystem.exists(sorted)
        XCTAssertFalse(folder)
        let after = await history.snapshot()
        XCTAssertEqual(after.undoEntries.map(\.name), ["Move"])
        XCTAssertTrue(after.redoEntries.isEmpty)
        let plain = await exists("plain.txt", in: archive)
        XCTAssertTrue(plain)
    }

    func testUndoingAGroupLetsGoOfWhatWasOnTheRedoStack() async throws {
        _ = try await applyPlan()
        // A plain change after the plan, undone, sits on the redo stack above the group.
        try await run(.copy(sources: [file("plain.txt", in: archive)], destinationDirectory: documents), group: nil)
        let plainUndone = await undoOne()
        XCTAssertTrue(plainUndone)
        let ready = await history.snapshot()
        XCTAssertEqual(ready.redoEntries.map(\.name), ["Copy"])
        // Undoing the group below it lets that go: it was made on a disk the group's Undo has since changed.
        let walked = await undoGroup()
        XCTAssertEqual(walked.undone, 5)
        let state = await history.snapshot()
        XCTAssertTrue(state.redoEntries.isEmpty)
        XCTAssertEqual(state.redoAvailability, .empty)
    }
}
