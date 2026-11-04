// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmOperations

final class K15OperationAdversarialTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/")
    private func boundary(_ index: Int, cancel: Bool) async throws {
        let fs = InMemoryFileSystem()
        let executor = OperationExecutor(fileSystem: fs)
        let steps = (0..<5).map { PlannedStep(kind: .createFile, destination: root.appendingPathComponent("file\($0)"), contents: Data([UInt8($0)])) }
        let plan = OperationPlan(command: .recovery, steps: steps)
        let task = Task {
            await executor.execute(plan) { progress in
                if progress.itemsDone == index && progress.currentName != nil {
                    if cancel { withUnsafeCurrentTask { $0?.cancel() } }
                    else if let destination = steps[index].destination { await fs.setFailure(.permissionDenied, at: destination) }
                }
            }
        }
        let result = await task.value
        XCTAssertNotNil(result.error)
        XCTAssertEqual(result.outcomes.count, 5)
        XCTAssertEqual(result.outcomes.filter(\.succeeded).count, index, "B-038")
        for offset in (index + 1)..<5 { XCTAssertEqual(result.outcomes[offset].result, .failure(.notAttempted)) }
        if let destination = steps[index].destination { await fs.setFailure(nil, at: destination) }
        for offset in 0..<5 {
            let exists = await fs.exists(root.appendingPathComponent("file\(offset)"))
            XCTAssertEqual(exists, offset < index)
        }
        let stored = await executor.journal.entry(result.id)
        let entry = try XCTUnwrap(stored)
        let inverse = UndoPlanner.inverse(of: entry, recordedOrigins: [:])
        if cancel {
            XCTAssertEqual(result.error, .cancelled)
            XCTAssertTrue(inverse.isExecutable)
            XCTAssertTrue(inverse.steps.allSatisfy { $0.kind == .trash }, "B-041")
            let undo = await executor.execute(inverse)
            XCTAssertNil(undo.error)
            for offset in 0..<index {
                let preserved = await fs.exists(URL(fileURLWithPath: "/.Trash/file\(offset)"))
                XCTAssertTrue(preserved)
            }
        } else { XCTAssertFalse(inverse.isExecutable, "Uncertain failed mutation requires reconciliation") }
        let journaled = await executor.journal.outcomes(for: result.id)
        XCTAssertEqual(journaled.count, result.outcomes.count)
    }
    /// B-038/F-061: inject failure before the first primitive.
    func testFailureAtStep0() async throws { try await boundary(0, cancel: false) }
    /// B-038/F-061: retain one successful primitive before failure.
    func testFailureAtStep1() async throws { try await boundary(1, cancel: false) }
    /// B-038/F-061: retain two successful primitives before failure.
    func testFailureAtStep2() async throws { try await boundary(2, cancel: false) }
    /// B-038/F-061: retain three successful primitives before failure.
    func testFailureAtStep3() async throws { try await boundary(3, cancel: false) }
    /// B-038/F-061: final-step failure retains the complete prefix.
    func testFailureAtStep4() async throws { try await boundary(4, cancel: false) }
    /// F-061/B-041: cancellation before mutation leaves no undo work.
    func testCancellationAtStep0() async throws { try await boundary(0, cancel: true) }
    /// F-061/B-041: cancellation journals and safely undoes one success.
    func testCancellationAtStep1() async throws { try await boundary(1, cancel: true) }
    /// F-061/B-041: cancellation journals and safely undoes two successes.
    func testCancellationAtStep2() async throws { try await boundary(2, cancel: true) }
    /// F-061/B-041: cancellation journals and safely undoes three successes.
    func testCancellationAtStep3() async throws { try await boundary(3, cancel: true) }
    /// F-061/B-041: cancellation journals and safely undoes four successes.
    func testCancellationAtStep4() async throws { try await boundary(4, cancel: true) }
    /// F-052/B-041: random plans preserve byte totals through copy/move and undo.
    func testRandomPlansConserveFilesAndTrashUndo() async throws {
        let fs = InMemoryFileSystem()
        let actual = OperationExecutor(fileSystem: fs)
        let sourceDirectory = URL(fileURLWithPath: "/source"), target = URL(fileURLWithPath: "/target")
        try await fs.createDirectory(at: sourceDirectory); try await fs.createDirectory(at: target)
        var seed: UInt64 = 819
        for index in 0..<40 {
            seed = seed &* 6364136223846793005 &+ 1
            let size = Int((seed >> 32) % 127) + 1
            let source = sourceDirectory.appendingPathComponent("file\(index)")
            try await fs.createFileExclusively(at: source, contents: Data(repeating: UInt8(index), count: size))
            let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [target])
            let copy = (seed >> 33) % 2 == 0
            let command: Command = copy ? .copy(sources: [source], destinationDirectory: target) : .move(sources: [source], destinationDirectory: target)
            let result = await actual.execute(OperationPlanner.plan(command, context: context))
            XCTAssertNil(result.error)
            let destination = target.appendingPathComponent(source.lastPathComponent)
            let entry = try await fs.entry(at: destination); XCTAssertEqual(entry.size, Int64(size))
            let stored = await actual.journal.entry(result.id)
            let inverse = UndoPlanner.inverse(of: try XCTUnwrap(stored), recordedOrigins: [:])
            XCTAssertTrue(inverse.isExecutable)
            let undone = await actual.execute(inverse); XCTAssertNil(undone.error)
            let original = try await fs.entry(at: source); XCTAssertEqual(original.size, Int64(size))
            let stillAtDestination = await fs.exists(destination); XCTAssertFalse(stillAtDestination)
            if copy {
                let retained = try await fs.entry(at: URL(fileURLWithPath: "/.Trash/" + source.lastPathComponent))
                XCTAssertEqual(retained.size, Int64(size))
            }
        }
    }
    /// B-107: timeout quarantines the executor against ambiguous late mutation retries.
    func testTimeoutQuarantinesExecutor() async {
        let fs = InMemoryFileSystem(), destination = URL(fileURLWithPath: "/new")
        await fs.setFailure(.timedOut, at: destination)
        let executor = OperationExecutor(fileSystem: fs)
        let plan = OperationPlan(command: .recovery, steps: [PlannedStep(kind: .createFile, destination: destination)])
        let first = await executor.execute(plan); XCTAssertEqual(first.error, .timedOut)
        await fs.setFailure(nil, at: destination)
        let second = await executor.execute(plan); XCTAssertEqual(second.error, .busy)
        let exists = await fs.exists(destination); XCTAssertFalse(exists)
    }
    /// B-039/F-052: case-insensitive collisions preserve the existing file.
    func testCaseInsensitiveKeepBoth() async throws {
        let fs = InMemoryFileSystem(caseSensitive: false)
        let source = URL(fileURLWithPath: "/Report.txt"), parent = URL(fileURLWithPath: "/target")
        try await fs.createDirectory(at: parent)
        try await fs.createFileExclusively(at: source, contents: Data([1, 2]))
        try await fs.createFileExclusively(at: parent.appendingPathComponent("REPORT.TXT"), contents: Data([9]))
        let context = try await PlanningContextBuilder(fileSystem: fs).build(sources: [source], destinations: [parent])
        let result = await OperationExecutor(fileSystem: fs).execute(OperationPlanner.plan(.copy(sources: [source], destinationDirectory: parent), context: context))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.outcomes.first?.destination?.lastPathComponent, "Report 2.txt")
        let old = try await fs.entry(at: parent.appendingPathComponent("REPORT.TXT")); XCTAssertEqual(old.size, 1)
    }
    /// F-051/B-037: acknowledging arbitrary subsets retains exactly the failed cuts.
    func testRandomClipboardAcknowledgments() {
        let urls = (0..<100).map { URL(fileURLWithPath: "/\($0)") }
        var transaction = ClipboardTransaction(mode: .cut, sources: urls, changeCount: 7)
        for residue in 0..<7 {
            let completed = Set(urls.enumerated().filter { $0.offset % 7 == residue }.map(\.element))
            let next = transaction.acknowledging(completed, currentChangeCount: 7)
            XCTAssertEqual(next?.sources, transaction.sources.filter { !completed.contains($0) })
            if let next { transaction = next }
        }
        XCTAssertTrue(transaction.sources.isEmpty)
    }
    /// F-051/B-036: external clipboard changes invalidate acknowledgments.
    func testStaleClipboardAcknowledgmentRejected() {
        let transaction = ClipboardTransaction(mode: .cut, sources: [root], changeCount: 5)
        XCTAssertNil(transaction.acknowledging([root], currentChangeCount: 6))
    }
    /// F-051: successful copies remain reusable after acknowledgment.
    func testCopyClipboardRemainsReusable() {
        let transaction = ClipboardTransaction(mode: .copy, sources: [root], changeCount: 5)
        XCTAssertEqual(transaction.acknowledging([root], currentChangeCount: 5), transaction)
    }
    /// B-038: completing an unknown journal ID cannot synthesize an undo entry.
    func testUnknownJournalCompletionRejected() async {
        let journal = OperationJournal()
        let accepted = await journal.complete(OperationResult(id: OperationID(), command: .recovery, outcomes: []))
        XCTAssertFalse(accepted)
        let entries = await journal.allEntries(); XCTAssertTrue(entries.isEmpty)
    }
    /// B-041: a successful mutation without identity metadata must not become destructive undo.
    func testMissingTokenBlocksUndo() {
        let step = PlannedStep(kind: .createFile, destination: URL(fileURLWithPath: "/new"))
        let id = OperationID(), plan = OperationPlan(command: .recovery, steps: [step])
        let result = OperationResult(id: id, command: .recovery, outcomes: [ItemOutcome(step: step, destination: step.destination, result: .success(nil))])
        XCTAssertFalse(UndoPlanner.inverse(of: JournalEntry(id: id, plan: plan, result: result), recordedOrigins: [:]).isExecutable)
    }
}
