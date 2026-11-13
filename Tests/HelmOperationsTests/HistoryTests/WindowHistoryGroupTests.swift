import Foundation
import XCTest
import HelmCore
import HelmOperations

/// A forward operation reserved under a group: the window's history names it after the group and its entry carries
/// the group, which is what lets several operations be undone as one.
final class WindowHistoryGroupTests: XCTestCase {
    private let group = HistoryGroup(name: "Organize “Downloads”")

    private func fixture(_ name: String) -> JournalEntry {
        let source = URL(fileURLWithPath: "/source/\(name)"), target = URL(fileURLWithPath: "/target/\(name)")
        let command = Command.copy(sources: [source], destinationDirectory: target.deletingLastPathComponent())
        let step = PlannedStep(kind: .copy, source: source, destination: target)
        let plan = OperationPlan(command: command, steps: [step])
        let id = OperationID()
        let change = ChangeToken(modificationDate: Date(timeIntervalSince1970: 1), size: 4)
        let evidence = FileMutationPrecondition(identity: FileObjectIdentity(scope: "test", object: name), changeToken: change, kind: .regular)
        let item = ItemOutcome(step: step, destination: target, result: .success(change),
                               destinationKind: .regular, destinationEvidence: evidence)
        return JournalEntry(id: id, plan: plan, result: OperationResult(id: id, command: command, outcomes: [item]))
    }
    /// Runs one forward operation to its end, under `group` when given.
    private func run(_ entry: JournalEntry, in history: WindowOperationHistory, group: HistoryGroup? = nil) async throws {
        let reserved = group == nil ? await history.beginForward(entry.plan.command)
            : await history.beginForward(entry.plan.command, group: group)
        let request = try XCTUnwrap(reserved)
        let bound = await history.bindExecution(request: request, operation: entry.id, plan: entry.plan)
        XCTAssertTrue(bound)
        let accepted = await history.completeForward(request: request, entry: entry)
        XCTAssertTrue(accepted)
    }
    /// Undoes the top entry, successfully.
    private func undo(in history: WindowOperationHistory) async throws {
        let begun = await history.beginUndo(recordedOrigins: [:])
        let request = try XCTUnwrap(begun)
        let id = OperationID()
        let bound = await history.bindExecution(request: request.request, operation: id, plan: request.plan)
        XCTAssertTrue(bound)
        let result = OperationResult(id: id, command: .recovery, outcomes: request.plan.steps.map {
            ItemOutcome(step: $0, destination: $0.destination, result: .success(nil))
        })
        let accepted = await history.complete(request: request.request, outcome: result)
        XCTAssertTrue(accepted)
    }

    func testAGroupedForwardIsReservedAndRecordedUnderItsGroupsName() async throws {
        let history = WindowOperationHistory()
        let entry = fixture("a")
        let reserved = await history.beginForward(entry.plan.command, group: group)
        let request = try XCTUnwrap(reserved)
        let pending = await history.snapshot()
        XCTAssertEqual(pending.pending, .forward(request, name: "Organize “Downloads”"))
        XCTAssertEqual(pending.undoAvailability, .busy)
        let bound = await history.bindExecution(request: request, operation: entry.id, plan: entry.plan)
        XCTAssertTrue(bound)
        let accepted = await history.completeForward(request: request, entry: entry)
        XCTAssertTrue(accepted)
        let state = await history.snapshot()
        XCTAssertEqual(state.undoEntries, [HistoryEntry(operationID: entry.id, name: "Organize “Downloads”", group: group)])
        XCTAssertEqual(state.undoAvailability, .available("Organize “Downloads”"))
    }

    func testAForwardWithoutAGroupIsNamedAfterItsCommandAsBefore() async throws {
        let history = WindowOperationHistory()
        let plain = fixture("a"), explicit = fixture("b")
        try await run(plain, in: history)
        let reserved = await history.beginForward(explicit.plan.command, group: nil)
        let request = try XCTUnwrap(reserved)
        let pending = await history.snapshot()
        XCTAssertEqual(pending.pending, .forward(request, name: "Copy"))
        let bound = await history.bindExecution(request: request, operation: explicit.id, plan: explicit.plan)
        XCTAssertTrue(bound)
        let accepted = await history.completeForward(request: request, entry: explicit)
        XCTAssertTrue(accepted)
        let state = await history.snapshot()
        XCTAssertEqual(state.undoEntries, [HistoryEntry(operationID: plain.id, name: "Copy"),
                                           HistoryEntry(operationID: explicit.id, name: "Copy")])
        XCTAssertEqual(state.undoEntries.map(\.group), [nil, nil])
    }

    func testEachCommandOfAGroupCarriesItAndTheOnesAroundItDoNot() async throws {
        let history = WindowOperationHistory()
        let before = fixture("before"), first = fixture("first"), second = fixture("second"), after = fixture("after")
        try await run(before, in: history)
        try await run(first, in: history, group: group)
        try await run(second, in: history, group: group)
        try await run(after, in: history)
        let state = await history.snapshot()
        XCTAssertEqual(state.undoEntries.map(\.name), ["Copy", "Organize “Downloads”", "Organize “Downloads”", "Copy"])
        XCTAssertEqual(state.undoEntries.map(\.group), [nil, group, group, nil])
        // Two groups of one name are still two groups.
        let other = HistoryGroup(name: group.name)
        try await run(fixture("other"), in: history, group: other)
        let later = await history.snapshot()
        XCTAssertEqual(later.undoEntries.last?.group, other)
        XCTAssertNotEqual(later.undoEntries.last?.group, group)
    }

    func testAnUndoneGroupedEntryCannotBeRedoneAndAnUngroupedOneCan() async throws {
        let history = WindowOperationHistory()
        try await run(fixture("plain"), in: history)
        try await run(fixture("grouped"), in: history, group: group)
        try await undo(in: history)
        let afterGrouped = await history.snapshot()
        XCTAssertEqual(afterGrouped.undoEntries.map(\.name), ["Copy"])
        XCTAssertTrue(afterGrouped.redoEntries.isEmpty, "A grouped entry reached the redo stack")
        let redo = await history.beginRedoForward()
        XCTAssertNil(redo)
        try await undo(in: history)
        let afterPlain = await history.snapshot()
        XCTAssertTrue(afterPlain.undoEntries.isEmpty)
        XCTAssertEqual(afterPlain.redoEntries.map(\.name), ["Copy"])
    }

    func testAGroupChangesNothingAboutAdmission() async throws {
        let history = WindowOperationHistory()
        // Recovery is never a forward operation, in a group or out of one.
        let recovery = await history.beginForward(.recovery, group: group)
        XCTAssertNil(recovery)
        let idle = await history.snapshot()
        XCTAssertNil(idle.pending)
        // One reservation at a time.
        let first = await history.beginForward(fixture("a").plan.command, group: group)
        XCTAssertNotNil(first)
        let second = await history.beginForward(fixture("b").plan.command, group: group)
        XCTAssertNil(second)
        // A grouped reservation that is given up leaves no group behind for the next forward.
        let aborted = await history.abortForward(request: try XCTUnwrap(first), failure: .cancelled)
        XCTAssertTrue(aborted)
        let next = fixture("c")
        try await run(next, in: history)
        let state = await history.snapshot()
        XCTAssertEqual(state.undoEntries, [HistoryEntry(operationID: next.id, name: "Copy")])
    }
}
