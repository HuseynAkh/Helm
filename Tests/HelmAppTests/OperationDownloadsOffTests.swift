#if os(macOS)
import AppKit
import XCTest
import HelmCore
import HelmApp
import HelmFileSystem
import HelmOperations
import HelmPersistence
@testable import HelmUI

/// A change run with downloads off reaches the file system with downloads off on every call, from planning to its
/// last step, and so does its Undo. An ordinary change, and its Undo, run as they always have.
@MainActor final class OperationDownloadsOffTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home/off", isDirectory: true)
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    private var sorted: URL { home.appendingPathComponent("Sorted", isDirectory: true) }
    private var inner: URL { documents.appendingPathComponent("Inner", isDirectory: true) }
    private let stick = URL(fileURLWithPath: "/Volumes/Stick", isDirectory: true)

    /// Documents holds three files and a folder, Inner, with one file in it. Sorted is empty, and so is a second
    /// disk, Stick, so a move there copies, checks the copy and puts the original in the Trash.
    private func fixture() async throws -> (OperationCoordinator, WindowOperationHistory, OperationRecordingFileSystem) {
        let env = try await AppEnvironment.test(home: home)
        let memory = InMemoryFileSystem(volumeIDs: [stick: "stick"])
        for folder in [URL(fileURLWithPath: "/home"), home, documents, inner, sorted, URL(fileURLWithPath: "/Volumes"), stick] {
            try await memory.createDirectory(at: folder)
        }
        for name in ["a.txt", "b.txt", "c.txt"] {
            try await memory.createFileExclusively(at: documents.appendingPathComponent(name), contents: Data(name.utf8))
        }
        try await memory.createFileExclusively(at: inner.appendingPathComponent("x.txt"), contents: Data("x".utf8))
        let recorder = OperationRecordingFileSystem(inner: memory, log: OperationCallLog(), control: OperationStallControl())
        let coordinator = OperationCoordinator(fileSystem: recorder, origins: env.trashOrigins, journal: env.journal)
        return (coordinator, WindowOperationHistory(), recorder)
    }
    private func name(_ text: String) throws -> ValidFileName { try XCTUnwrap(ValidFileName(text)) }
    /// The five kinds of change a plan makes, and a move to another disk, which copies, checks and trashes.
    private func commands() throws -> [Command] {
        [.copy(sources: [documents.appendingPathComponent("a.txt")], destinationDirectory: sorted),
         .move(sources: [inner], destinationDirectory: stick),
         .rename(RenamePair(source: documents.appendingPathComponent("b.txt"), newName: try name("beta.txt"))),
         .createFolder(parent: documents, name: try name("New")),
         .trash(items: [documents.appendingPathComponent("c.txt")])]
    }
    /// Runs each command through the coordinator and answers, for each, every call the file system saw and whether
    /// downloads were off for it.
    private func runEach(downloadsOff: Bool, _ coordinator: OperationCoordinator, _ history: WindowOperationHistory,
                         _ recorder: OperationRecordingFileSystem) async throws -> [[OperationCall]] {
        var calls: [[OperationCall]] = []
        for command in try commands() {
            recorder.log.reset()
            let scope = OperationCoordinator.scope(of: command)
            let outcome = await coordinator.run(command, sources: scope.sources, destinations: scope.destinations, history: history,
                                                resolver: nil, downloadsOff: downloadsOff)
            guard case .success(let result) = outcome else { XCTFail("\(command) didn't run: \(outcome)"); return calls }
            XCTAssertNil(result.error, "\(command) failed")
            calls.append(recorder.log.calls)
        }
        return calls
    }

    func testEveryCallOfAChangeWithDownloadsOffHasThemOff() async throws {
        let (coordinator, history, recorder) = try await fixture()
        let runs = try await runEach(downloadsOff: true, coordinator, history, recorder)
        XCTAssertEqual(runs.count, 5)
        for (index, calls) in runs.enumerated() {
            // Planning reads the folders a change writes to; steps change items. Both happened, with downloads off.
            XCTAssertTrue(calls.contains { $0.method == "enumerate" }, "command \(index) was never planned")
            XCTAssertTrue(calls.contains { $0.method == "isCaseSensitive" })
            XCTAssertTrue(calls.contains { $0.method == "availableCapacity" })
            XCTAssertTrue(calls.contains { $0.method.hasPrefix("mutate") || $0.method == "createDirectory" }, "command \(index) changed nothing")
            let on = calls.filter { !$0.downloadsOff }
            XCTAssertEqual(on.map { "\($0.method) \($0.path)" }, [], "command \(index) reached the file system with downloads on")
        }
        // The move to another disk: its copy, the reads that check the copy, and its last step, the original going
        // to the Trash, all ran with downloads off.
        let move = runs[1]
        XCTAssertTrue(move.contains { $0.method == "mutate copy" && $0.path == inner.path && $0.downloadsOff })
        XCTAssertTrue(move.contains { $0.method == "enumerate" && $0.path == stick.appendingPathComponent("Inner").path && $0.downloadsOff },
                      "the copy was checked")
        let last = try XCTUnwrap(move.last { $0.method.hasPrefix("mutate") })
        XCTAssertEqual(last.method, "mutate trash")
        XCTAssertEqual(last.path, inner.path)
        XCTAssertTrue(last.downloadsOff)
        let gone = await recorder.inner.exists(inner)
        XCTAssertFalse(gone)
        let arrived = await recorder.inner.exists(stick.appendingPathComponent("Inner/x.txt"))
        XCTAssertTrue(arrived)
    }

    func testAnOrdinaryChangeRunsWithDownloadsOnAsBefore() async throws {
        let (coordinator, history, recorder) = try await fixture()
        let runs = try await runEach(downloadsOff: false, coordinator, history, recorder)
        XCTAssertEqual(runs.count, 5)
        for (index, calls) in runs.enumerated() {
            XCTAssertFalse(calls.isEmpty)
            let off = calls.filter(\.downloadsOff)
            XCTAssertEqual(off.map { "\($0.method) \($0.path)" }, [], "command \(index) ran with downloads off")
        }
        XCTAssertEqual(recorder.control.reopenAsks, 0, "an ordinary change never asks to reopen anything")
    }

    func testAnUndoWithDownloadsOffHasThemOffAndAnOrdinaryOneDoesNot() async throws {
        let (coordinator, history, recorder) = try await fixture()
        _ = try await runEach(downloadsOff: true, coordinator, history, recorder)
        // The Trash, then the new folder: one Undo with downloads off, one without.
        recorder.log.reset()
        let first = await coordinator.undo(history: history, downloadsOff: true)
        guard case .success(let undoneTrash) = first else { return XCTFail("the Trash wasn't undone: \(first)") }
        XCTAssertNil(undoneTrash.error)
        let offCalls = recorder.log.calls
        XCTAssertTrue(offCalls.contains { $0.method.hasPrefix("mutate") })
        XCTAssertEqual(offCalls.filter { !$0.downloadsOff }.map { "\($0.method) \($0.path)" }, [])
        let back = await recorder.inner.exists(documents.appendingPathComponent("c.txt"))
        XCTAssertTrue(back)

        recorder.log.reset()
        let second = await coordinator.undo(history: history)
        guard case .success(let undoneFolder) = second else { return XCTFail("the new folder wasn't undone: \(second)") }
        XCTAssertNil(undoneFolder.error)
        let onCalls = recorder.log.calls
        XCTAssertTrue(onCalls.contains { $0.method.hasPrefix("mutate") })
        XCTAssertEqual(onCalls.filter(\.downloadsOff).map { "\($0.method) \($0.path)" }, [])
    }
}

/// The coordinator's side of the stall latch. A change that stalled shuts every later one out; once the person has
/// acknowledged it and the stalled call has returned, in either order, a later, unrelated change runs. A step that
/// stalled on a read before it changed anything leaves nothing to acknowledge, so later changes go on by themselves.
@MainActor final class OperationStallLatchCoordinatorTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home/stall", isDirectory: true)
    private var documents: URL { home.appendingPathComponent("Documents", isDirectory: true) }
    private var stuck: URL { documents.appendingPathComponent("stuck.txt") }
    private var target: URL { home.appendingPathComponent("Target", isDirectory: true) }
    private var deep: URL { home.appendingPathComponent("Deep", isDirectory: true) }
    private var deeper: URL { deep.appendingPathComponent("Inner", isDirectory: true) }
    private var other: URL { home.appendingPathComponent("Other", isDirectory: true) }

    private func fixture() async throws -> (OperationCoordinator, WindowOperationHistory, OperationRecordingFileSystem) {
        let env = try await AppEnvironment.test(home: home)
        let memory = InMemoryFileSystem()
        for folder in [URL(fileURLWithPath: "/home"), home, documents, target, deep, deeper, other] {
            try await memory.createDirectory(at: folder)
        }
        try await memory.createFileExclusively(at: stuck, contents: Data("stuck".utf8))
        let control = OperationStallControl()
        control.stallsChange(of: stuck)
        control.stallsRead(of: deep)
        let recorder = OperationRecordingFileSystem(inner: memory, log: OperationCallLog(), control: control)
        let coordinator = OperationCoordinator(fileSystem: recorder, origins: env.trashOrigins, journal: env.journal)
        return (coordinator, WindowOperationHistory(), recorder)
    }
    private func run(_ command: Command, _ coordinator: OperationCoordinator, _ history: WindowOperationHistory) async throws -> OperationResult {
        let scope = OperationCoordinator.scope(of: command)
        let outcome = await coordinator.run(command, sources: scope.sources, destinations: scope.destinations, history: history, resolver: nil)
        guard case .success(let result) = outcome else { throw OperationStallTestError.notRun("\(outcome)") }
        return result
    }
    /// Moves stuck.txt into Target, which stalls inside the change, and acknowledges it as the window does.
    private func stallAndAcknowledge(_ coordinator: OperationCoordinator, _ history: WindowOperationHistory) async throws {
        let result = try await run(.move(sources: [stuck], destinationDirectory: target), coordinator, history)
        XCTAssertEqual(result.error, .timedOut)
        let state = await history.snapshot()
        XCTAssertNotNil(state.reconciliation, "a stalled change is unsure")
        let acknowledged = await history.acknowledgeReconciliation()
        XCTAssertTrue(acknowledged)
        await coordinator.clearStallIfSettled()
    }
    private func unrelated(_ name: String, _ coordinator: OperationCoordinator, _ history: WindowOperationHistory) async throws -> OperationResult {
        try await run(.createFolder(parent: other, name: try XCTUnwrap(ValidFileName(name))), coordinator, history)
    }
    private func made(_ name: String, _ recorder: OperationRecordingFileSystem) async -> Bool {
        await recorder.inner.exists(other.appendingPathComponent(name))
    }

    func testAStallThatSettledBeforeItWasAcknowledgedLetsALaterChangeRun() async throws {
        let (coordinator, history, recorder) = try await fixture()
        try await stallAndAcknowledge(coordinator, history)
        XCTAssertEqual(recorder.control.reopenAsks, 1, "acknowledging asked the file system")
        let later = try await unrelated("Fresh", coordinator, history)
        XCTAssertNil(later.error)
        let exists = await made("Fresh", recorder)
        XCTAssertTrue(exists, "a later, unrelated change ran")
    }

    func testAStallStillOutWhenAcknowledgedLetsALaterChangeRunOnceItReturns() async throws {
        let (coordinator, history, recorder) = try await fixture()
        recorder.control.reopens = false
        try await stallAndAcknowledge(coordinator, history)
        let refused = try await unrelated("Fresh", coordinator, history)
        XCTAssertEqual(refused.error, .busy, "refused while the stalled call is still out")
        let early = await made("Fresh", recorder)
        XCTAssertFalse(early)
        // The call returned. Nobody acknowledges anything again: the next change asks before it starts, and runs.
        recorder.control.reopens = true
        let later = try await unrelated("Fresh", coordinator, history)
        XCTAssertNil(later.error)
        let exists = await made("Fresh", recorder)
        XCTAssertTrue(exists)
        // Settled, later changes no longer ask.
        let asks = recorder.control.reopenAsks
        let next = try await unrelated("Second", coordinator, history)
        XCTAssertNil(next.error)
        XCTAssertEqual(recorder.control.reopenAsks, asks)
    }

    func testAStallThatWasNeverAcknowledgedKeepsChangesOut() async throws {
        let (coordinator, history, recorder) = try await fixture()
        let result = try await run(.move(sources: [stuck], destinationDirectory: target), coordinator, history)
        XCTAssertEqual(result.error, .timedOut)
        XCTAssertEqual(recorder.control.reopenAsks, 0, "nothing reopens before the person acknowledges the change")
        // The window's history refuses until then, and so does the executor.
        let outcome = await coordinator.run(.createFolder(parent: other, name: try XCTUnwrap(ValidFileName("Fresh"))),
                                            sources: [], destinations: [other], history: history, resolver: nil)
        XCTAssertEqual(outcome.failure, .busy)
        let elsewhere = try await unrelated("Fresh", coordinator, WindowOperationHistory())
        XCTAssertEqual(elsewhere.error, .busy, "another window is refused too")
        let exists = await made("Fresh", recorder)
        XCTAssertFalse(exists)
    }

    func testOnlyTheStalledWindowsAcknowledgementReopensChanges() async throws {
        let (coordinator, stalledWindow, recorder) = try await fixture()
        let otherWindow = WindowOperationHistory()
        let result = try await run(.move(sources: [stuck], destinationDirectory: target), coordinator, stalledWindow)
        XCTAssertEqual(result.error, .timedOut)
        // Another window acknowledging an unsure change of its own asks the coordinator to reopen. It must not.
        await coordinator.clearStallIfSettled()
        let refused = try await unrelated("Fresh", coordinator, otherWindow)
        XCTAssertEqual(refused.error, .busy, "the stalled window hasn't acknowledged its change yet")
        let early = await made("Fresh", recorder)
        XCTAssertFalse(early)
        // The stalled window acknowledges its change: later changes run, in any window.
        let acknowledged = await stalledWindow.acknowledgeReconciliation()
        XCTAssertTrue(acknowledged)
        await coordinator.clearStallIfSettled()
        let later = try await unrelated("Fresh", coordinator, otherWindow)
        XCTAssertNil(later.error)
        let exists = await made("Fresh", recorder)
        XCTAssertTrue(exists)
    }

    func testAStallOnAReadThatChangedNothingLetsLaterChangesRun() async throws {
        let (coordinator, history, recorder) = try await fixture()
        // A new folder in Deep/Inner: before making it, the executor reads each folder above it, and Deep stalls.
        let stalled = try await run(.createFolder(parent: deeper, name: try XCTUnwrap(ValidFileName("New"))), coordinator, history)
        XCTAssertEqual(stalled.error, .timedOut)
        XCTAssertEqual(stalled.outcomes.map(\.requiresReconciliation), [false], "nothing was changed, so nothing is unsure")
        let state = await history.snapshot()
        XCTAssertNil(state.reconciliation, "there is nothing to acknowledge")
        let later = try await unrelated("Fresh", coordinator, history)
        XCTAssertNil(later.error, "a later, unrelated change runs")
        let exists = await made("Fresh", recorder)
        XCTAssertTrue(exists)
    }

    func testAStallOnAReadStillOutLetsLaterChangesRunOnceItReturns() async throws {
        let (coordinator, history, recorder) = try await fixture()
        recorder.control.reopens = false
        let stalled = try await run(.createFolder(parent: deeper, name: try XCTUnwrap(ValidFileName("New"))), coordinator, history)
        XCTAssertEqual(stalled.error, .timedOut)
        let refused = try await unrelated("Fresh", coordinator, history)
        XCTAssertEqual(refused.error, .busy)
        recorder.control.reopens = true
        let later = try await unrelated("Fresh", coordinator, history)
        XCTAssertNil(later.error)
    }
}

private enum OperationStallTestError: Error { case notRun(String) }

private extension Result where Failure == OperationCoordinator.Failure {
    var failure: OperationCoordinator.Failure? {
        if case .failure(let value) = self { return value }
        return nil
    }
}

/// One call a file system was asked to make: which, on what, and whether downloads were off for it.
private struct OperationCall: Sendable {
    let method: String
    let path: String
    let downloadsOff: Bool
}

/// Every call a file system was asked to make, in order.
private final class OperationCallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [OperationCall] = []
    func note(_ method: String, _ url: URL) {
        let call = OperationCall(method: method, path: url.standardizedFileURL.path, downloadsOff: DatalessGuard.isOff)
        lock.withLock { entries.append(call) }
    }
    var calls: [OperationCall] { lock.withLock { entries } }
    func reset() { lock.withLock { entries = [] } }
}

/// Which calls stall, as a disk that stopped answering makes them, and what the file system answers when asked to
/// reopen after a stall.
private final class OperationStallControl: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: Set<String> = []
    private var reads: Set<String> = []
    private var answer = true
    private var asks = 0
    func stallsChange(of url: URL) { lock.withLock { _ = changes.insert(url.standardizedFileURL.path) } }
    func stallsRead(of url: URL) { lock.withLock { _ = reads.insert(url.standardizedFileURL.path) } }
    func changeStalls(_ url: URL) -> Bool { lock.withLock { changes.contains(url.standardizedFileURL.path) } }
    func readStalls(_ url: URL) -> Bool { lock.withLock { reads.contains(url.standardizedFileURL.path) } }
    var reopens: Bool {
        get { lock.withLock { answer } }
        set { lock.withLock { answer = newValue } }
    }
    var reopenAsks: Int { lock.withLock { asks } }
    func askedToReopen() -> Bool { lock.withLock { asks += 1; return answer } }
}

/// An in-memory file system that notes every call it is asked to make, and stalls the calls its control names.
private struct OperationRecordingFileSystem: FileSystem {
    let inner: InMemoryFileSystem
    let log: OperationCallLog
    let control: OperationStallControl
    func enumerate(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<[FileEntry], Error> {
        log.note("enumerate", directory)
        return inner.enumerate(directory, options: options)
    }
    func entry(at url: URL) async throws -> FileEntry {
        log.note("entry", url)
        if control.readStalls(url) { throw FileSystemError.timedOut }
        return try await inner.entry(at: url)
    }
    func exists(_ url: URL) async -> Bool { log.note("exists", url); return await inner.exists(url) }
    func isDirectory(_ url: URL, resolvingSymlinks: Bool) async -> Bool {
        log.note("isDirectory", url)
        return await inner.isDirectory(url, resolvingSymlinks: resolvingSymlinks)
    }
    func childNames(of directory: URL) async throws -> Set<String> {
        log.note("childNames", directory)
        return try await inner.childNames(of: directory)
    }
    func mutationPrecondition(at source: URL) async throws -> FileMutationPrecondition {
        log.note("mutationPrecondition", source)
        return try await inner.mutationPrecondition(at: source)
    }
    func mutate(_ mutation: ConditionalFileMutation, source: URL, requiring precondition: FileMutationPrecondition) async throws -> URL? {
        let kind: String
        switch mutation {
        case .move: kind = "move"
        case .copy: kind = "copy"
        case .trash: kind = "trash"
        }
        log.note("mutate " + kind, source)
        if control.changeStalls(source) { throw FileSystemError.timedOut }
        return try await inner.mutate(mutation, source: source, requiring: precondition)
    }
    func copyItem(at source: URL, to destination: URL) async throws {
        log.note("copyItem", source)
        try await inner.copyItem(at: source, to: destination)
    }
    func moveItem(at source: URL, to destination: URL) async throws {
        log.note("moveItem", source)
        try await inner.moveItem(at: source, to: destination)
    }
    func replaceItem(at destination: URL, with temporary: URL, backup: URL) async throws {
        log.note("replaceItem", destination)
        try await inner.replaceItem(at: destination, with: temporary, backup: backup)
    }
    func applyDirectoryMetadata(from source: URL, to destination: URL) async throws {
        log.note("applyDirectoryMetadata", destination)
        try await inner.applyDirectoryMetadata(from: source, to: destination)
    }
    func trashItem(at url: URL) async throws -> URL? { log.note("trashItem", url); return try await inner.trashItem(at: url) }
    func removeItem(at url: URL) async throws { log.note("removeItem", url); try await inner.removeItem(at: url) }
    func createDirectory(at url: URL) async throws {
        log.note("createDirectory", url)
        if control.changeStalls(url) { throw FileSystemError.timedOut }
        try await inner.createDirectory(at: url)
    }
    func createFileExclusively(at url: URL, contents: Data) async throws {
        log.note("createFileExclusively", url)
        try await inner.createFileExclusively(at: url, contents: contents)
    }
    func createSymbolicLink(at url: URL, destination: URL) async throws {
        log.note("createSymbolicLink", url)
        try await inner.createSymbolicLink(at: url, destination: destination)
    }
    func createAlias(for url: URL, at destination: URL) async throws {
        log.note("createAlias", destination)
        try await inner.createAlias(for: url, at: destination)
    }
    func isCaseSensitive(at url: URL) async throws -> Bool { log.note("isCaseSensitive", url); return try await inner.isCaseSensitive(at: url) }
    func volumeIdentifier(for url: URL) async throws -> String {
        log.note("volumeIdentifier", url)
        return try await inner.volumeIdentifier(for: url)
    }
    func availableCapacity(of url: URL) async throws -> Int64 {
        log.note("availableCapacity", url)
        return try await inner.availableCapacity(of: url)
    }
    func sizeOfTree(at url: URL) -> AsyncThrowingStream<Int64, Error> { log.note("sizeOfTree", url); return inner.sizeOfTree(at: url) }
    func makeMonitor(for directory: URL) -> any DirectoryMonitor { inner.makeMonitor(for: directory) }
    func reopenAfterStall() async -> Bool { control.askedToReopen() }
}
#endif
