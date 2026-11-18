import Foundation
import XCTest
import HelmCore
import HelmOperations

/// A permissions change is one entry in the window's history, between its operations: Undo takes it back and Redo
/// makes it again, in turn with the rest, and nothing else starts while one is being made.
final class PermissionHistoryTests: XCTestCase {
    private let item = URL(fileURLWithPath: "/home/pat/notes.txt")
    private let identity = FileObjectIdentity(scope: "native:1", object: "42")
    private var change: PermissionChange { PermissionChange(item: item, identity: identity, before: 0o644, after: 0o604) }

    private func unwrap<T>(_ value: T?, file: StaticString = #filePath, line: UInt = #line) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    private func recorded(_ history: WindowOperationHistory, _ change: PermissionChange) async throws {
        let request = await history.beginPermissionChange()
        let accepted = await history.finishPermissionChange(request: try XCTUnwrap(request), change: change)
        XCTAssertTrue(accepted)
    }
    /// A copy, recorded as the executor's journal would hand it over.
    private func copied(_ history: WindowOperationHistory) async throws {
        let source = URL(fileURLWithPath: "/home/pat/a.txt"), target = URL(fileURLWithPath: "/home/pat/Sorted/a.txt")
        let command = Command.copy(sources: [source], destinationDirectory: target.deletingLastPathComponent())
        let step = PlannedStep(kind: .copy, source: source, destination: target)
        let plan = OperationPlan(command: command, steps: [step])
        let id = OperationID()
        let token = ChangeToken(modificationDate: Date(timeIntervalSince1970: 1), size: 4)
        let outcome = ItemOutcome(step: step, destination: target, result: .success(token), destinationKind: .regular,
                                  destinationEvidence: FileMutationPrecondition(identity: identity, changeToken: token, kind: .regular))
        let entry = JournalEntry(id: id, plan: plan, result: OperationResult(id: id, command: command, outcomes: [outcome]))
        let request = try unwrap(await history.beginForward(command))
        let bound = await history.bindExecution(request: request, operation: id, plan: plan)
        let accepted = await history.completeForward(request: request, entry: entry)
        XCTAssertTrue(bound && accepted)
    }

    func testAChangeIsOneEntryThatUndoTakesBackAndRedoMakesAgain() async throws {
        let history = WindowOperationHistory()
        try await recorded(history, change)
        var state = await history.snapshot()
        XCTAssertEqual(state.undoAvailability, .available("Change Permissions"))
        let toUndo = await history.permissionChangeToUndo()
        XCTAssertEqual(toUndo, change)

        let undo = try unwrap(await history.beginPermissionUndo())
        XCTAssertEqual(undo.change, change)
        let restored = await history.finishPermissionUndo(request: undo.request, restored: true)
        XCTAssertTrue(restored)
        state = await history.snapshot()
        XCTAssertEqual(state.undoAvailability, .empty)
        XCTAssertEqual(state.redoAvailability, .unsupported("Change Permissions"))
        XCTAssertEqual(state.lastOutcome, .succeeded)
        let toRedo = await history.permissionChangeToRedo()
        XCTAssertEqual(toRedo, change)

        let redo = try unwrap(await history.beginPermissionRedo())
        XCTAssertEqual(redo.change, change)
        // What the disk kept may differ from what was asked; the new entry records what it kept.
        let kept = PermissionChange(item: item, identity: identity, before: 0o644, after: 0o600)
        let made = await history.finishPermissionChange(request: redo.request, change: kept)
        XCTAssertTrue(made)
        state = await history.snapshot()
        XCTAssertEqual(state.undoAvailability, .available("Change Permissions"))
        XCTAssertEqual(state.redoAvailability, .empty)
        let next = await history.permissionChangeToUndo()
        XCTAssertEqual(next, kept)
    }

    /// A change that was refused, or changed nothing, leaves no entry, and the history is free again.
    func testNothingChangedRecordsNothing() async throws {
        let history = WindowOperationHistory()
        let request = try unwrap(await history.beginPermissionChange())
        let ended = await history.finishPermissionChange(request: request, change: nil, failure: "It’s locked")
        XCTAssertTrue(ended)
        let unchanged = PermissionChange(item: item, identity: identity, before: 0o644, after: 0o644)
        let second = try unwrap(await history.beginPermissionChange())
        let same = await history.finishPermissionChange(request: second, change: unchanged)
        XCTAssertTrue(same)
        let state = await history.snapshot()
        XCTAssertEqual(state.undoAvailability, .empty)
        XCTAssertNil(state.pending)
    }

    /// An Undo that's refused, such as for an item changed since, changes nothing and leaves the entry for Undo, as an
    /// operation's refused Undo does.
    func testARefusedUndoKeepsTheEntry() async throws {
        let history = WindowOperationHistory()
        try await recorded(history, change)
        let undo = try unwrap(await history.beginPermissionUndo())
        let ended = await history.finishPermissionUndo(request: undo.request, restored: false, failure: "changed since")
        XCTAssertTrue(ended)
        let state = await history.snapshot()
        XCTAssertEqual(state.undoAvailability, .available("Change Permissions"))
        XCTAssertEqual(state.redoAvailability, .empty)
        XCTAssertEqual(state.lastOutcome, .refused("changed since"))
    }

    /// While a change is being made the history is reserved: no operation, Undo or other change starts, and only the
    /// change's own reservation ends it.
    func testWhileAChangeIsMadeNothingElseStarts() async throws {
        let history = WindowOperationHistory()
        try await recorded(history, change)
        let request = try unwrap(await history.beginPermissionChange())
        let forward = await history.beginForward(.trash(items: [item]))
        XCTAssertNil(forward)
        let another = await history.beginPermissionChange()
        XCTAssertNil(another)
        let undo = await history.beginPermissionUndo()
        XCTAssertNil(undo)
        let plain = await history.beginUndo(recordedOrigins: [:])
        XCTAssertNil(plain)
        let foreign = await history.finishPermissionChange(request: HistoryRequestID(), change: change)
        XCTAssertFalse(foreign)
        let wrongKind = await history.finishPermissionUndo(request: request, restored: true)
        XCTAssertFalse(wrongKind)
        // An executor's result can't take the reservation over either.
        let bound = await history.bindExecution(request: request, operation: OperationID(),
                                                plan: OperationPlan(command: .trash(items: [item]), steps: []))
        XCTAssertFalse(bound)
        let ended = await history.finishPermissionChange(request: request, change: change)
        XCTAssertTrue(ended)
        let state = await history.snapshot()
        XCTAssertEqual(state.undoEntries.count, 2)
    }

    /// Between operations, Undo takes them back in turn: the latest first, whichever it is.
    func testChangesAndOperationsAreUndoneInTurn() async throws {
        let history = WindowOperationHistory()
        try await copied(history)
        try await recorded(history, change)
        var state = await history.snapshot()
        XCTAssertEqual(state.undoEntries.map(\.name), ["Copy", "Change Permissions"])
        let undo = try unwrap(await history.beginPermissionUndo())
        let restored = await history.finishPermissionUndo(request: undo.request, restored: true)
        XCTAssertTrue(restored)
        // The copy is next, and it isn't a permissions change.
        let none = await history.permissionChangeToUndo()
        XCTAssertNil(none)
        let notMine = await history.beginPermissionUndo()
        XCTAssertNil(notMine)
        state = await history.snapshot()
        XCTAssertEqual(state.undoAvailability, .available("Copy"))
        let copyUndo = await history.beginUndo(recordedOrigins: [:])
        XCTAssertNotNil(copyUndo)
    }

    /// A new change lets go of what Redo held, as a new operation does.
    func testANewChangeLetsGoOfRedo() async throws {
        let history = WindowOperationHistory()
        try await recorded(history, change)
        let undo = try unwrap(await history.beginPermissionUndo())
        await history.finishPermissionUndo(request: undo.request, restored: true)
        try await recorded(history, PermissionChange(item: item, identity: identity, before: 0o644, after: 0o640))
        let state = await history.snapshot()
        XCTAssertEqual(state.redoAvailability, .empty)
        let redo = await history.beginPermissionRedo()
        XCTAssertNil(redo)
    }
}
