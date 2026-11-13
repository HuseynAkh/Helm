import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmOperations

/// A step that stalls refuses every later operation as busy, since a call that timed out may still finish. The latch
/// lets go only when the file system says every stalled call has returned, and an unrelated operation then runs.
final class StallLatchTests: XCTestCase {
    private let documents = URL(fileURLWithPath: "/home/latch/Documents", isDirectory: true)
    private var stuck: URL { documents.appendingPathComponent("stuck.txt") }
    private var target: URL { documents.appendingPathComponent("Target", isDirectory: true) }
    private var other: URL { URL(fileURLWithPath: "/home/latch/Other", isDirectory: true) }

    private func fixture() async throws -> (StallLatchFileSystem, OperationExecutor) {
        let memory = InMemoryFileSystem()
        for folder in [URL(fileURLWithPath: "/home"), URL(fileURLWithPath: "/home/latch"), documents, target, other] {
            try await memory.createDirectory(at: folder)
        }
        try await memory.createFileExclusively(at: stuck, contents: Data("stuck".utf8))
        let fileSystem = StallLatchFileSystem(inner: memory, control: StallLatchControl(stalling: stuck))
        return (fileSystem, OperationExecutor(fileSystem: fileSystem, origins: InMemoryTrashOrigins()))
    }
    private func plan(_ command: Command, sources: [URL], destinations: [URL], on fileSystem: StallLatchFileSystem) async throws -> OperationPlan {
        let context = try await PlanningContextBuilder(fileSystem: fileSystem).build(sources: sources, destinations: destinations)
        let plan = OperationPlanner.plan(command, context: context)
        XCTAssertTrue(plan.isExecutable)
        XCTAssertFalse(plan.steps.isEmpty)
        return plan
    }
    /// Moves stuck.txt into Target, which stalls inside the file system's move.
    private func stall(_ executor: OperationExecutor, on fileSystem: StallLatchFileSystem) async throws {
        let move = try await plan(.move(sources: [stuck], destinationDirectory: target), sources: [stuck], destinations: [target], on: fileSystem)
        let result = await executor.execute(move)
        XCTAssertEqual(result.error, .timedOut)
        XCTAssertEqual(result.outcomes.map(\.requiresReconciliation), [true], "a stalled move may still finish")
    }
    /// A new folder in Other, which has nothing to do with the stalled move.
    private func unrelated(_ executor: OperationExecutor, on fileSystem: StallLatchFileSystem, named name: String) async throws -> OperationResult {
        let folder = try XCTUnwrap(ValidFileName(name))
        let create = try await plan(.createFolder(parent: other, name: folder), sources: [], destinations: [other], on: fileSystem)
        return await executor.execute(create)
    }

    func testAStalledStepRefusesEveryLaterOperation() async throws {
        let (fileSystem, executor) = try await fixture()
        try await stall(executor, on: fileSystem)
        let later = try await unrelated(executor, on: fileSystem, named: "Fresh")
        XCTAssertEqual(later.error, .busy)
        let made = await fileSystem.inner.exists(other.appendingPathComponent("Fresh"))
        XCTAssertFalse(made, "nothing ran while the latch was set")
    }

    func testTheLatchLetsGoOnlyOnceTheFileSystemSaysEveryStalledCallReturned() async throws {
        let (fileSystem, executor) = try await fixture()
        try await stall(executor, on: fileSystem)

        // A stalled call is still out: the file system says so, and the latch stays.
        fileSystem.control.reopens = false
        let early = await executor.clearQuarantine()
        XCTAssertFalse(early)
        XCTAssertEqual(fileSystem.control.reopenAsks, 1, "the file system was asked")
        let refused = try await unrelated(executor, on: fileSystem, named: "Fresh")
        XCTAssertEqual(refused.error, .busy, "still refused while a stalled call is out")
        let asked = await executor.clearQuarantine()
        XCTAssertFalse(asked, "asked again, the answer is still no")
        XCTAssertEqual(fileSystem.control.reopenAsks, 2)

        // The call returned: the latch lets go, and an unrelated operation runs.
        fileSystem.control.reopens = true
        let settled = await executor.clearQuarantine()
        XCTAssertTrue(settled)
        XCTAssertEqual(fileSystem.control.reopenAsks, 3)
        let later = try await unrelated(executor, on: fileSystem, named: "Fresh")
        XCTAssertNil(later.error)
        XCTAssertEqual(later.succeededCount, 1)
        let made = await fileSystem.inner.exists(other.appendingPathComponent("Fresh"))
        XCTAssertTrue(made, "a later, unrelated operation ran")
        // Another after it runs too: the latch stays open.
        let next = try await unrelated(executor, on: fileSystem, named: "Second")
        XCTAssertNil(next.error)
    }

    func testANewStallSetsTheLatchAgain() async throws {
        let (fileSystem, executor) = try await fixture()
        try await stall(executor, on: fileSystem)
        let settled = await executor.clearQuarantine()
        XCTAssertTrue(settled)
        // The same move stalls again: the latch is set again, as the first time.
        try await stall(executor, on: fileSystem)
        let later = try await unrelated(executor, on: fileSystem, named: "Fresh")
        XCTAssertEqual(later.error, .busy)
    }

    func testWithoutAStallClearingAsksTheFileSystemAndChangesNothing() async throws {
        let (fileSystem, executor) = try await fixture()
        fileSystem.control.reopens = false
        let answer = await executor.clearQuarantine()
        XCTAssertFalse(answer, "it answers what the file system says")
        XCTAssertEqual(fileSystem.control.reopenAsks, 1)
        // Nothing stalled, so nothing was shut: operations run as before.
        let later = try await unrelated(executor, on: fileSystem, named: "Fresh")
        XCTAssertNil(later.error)
    }

    func testAStallWhileTheFileSystemIsAskedKeepsTheLatch() async throws {
        let (fileSystem, executor) = try await fixture()
        // The file system holds its answer until the stall below has happened, then says every call returned. That
        // answer is about the calls made before it was asked, so it can't let the newer stall go.
        fileSystem.control.holdsAnswer = true
        let clearing = Task { await executor.clearQuarantine() }
        let asked = await until { fileSystem.control.reopenAsks == 1 }
        XCTAssertTrue(asked, "the file system was never asked")
        try await stall(executor, on: fileSystem)
        fileSystem.control.release()
        let answer = await clearing.value
        XCTAssertFalse(answer)
        let later = try await unrelated(executor, on: fileSystem, named: "Fresh")
        XCTAssertEqual(later.error, .busy, "the newer stall still holds the latch")
        // Asked again, now that it has returned, the latch lets go.
        fileSystem.control.holdsAnswer = false
        let settled = await executor.clearQuarantine()
        XCTAssertTrue(settled)
        let after = try await unrelated(executor, on: fileSystem, named: "Fresh")
        XCTAssertNil(after.error)
    }

    /// Waits for `condition`, generously, since a busy Mac runs tasks late; a wait that is met ends at once.
    private func until(_ timeout: TimeInterval = 30, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return true
    }
}

/// What the stand-in file system does about a stall: which item's move stalls, what it answers when asked to reopen,
/// how often it was asked, and whether it holds that answer until released.
private final class StallLatchControl: @unchecked Sendable {
    private let lock = NSLock()
    private let stalling: URL
    private var reopensValue = true
    private var asks = 0
    private var holds = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    init(stalling: URL) { self.stalling = stalling }
    var reopens: Bool {
        get { lock.withLock { reopensValue } }
        set { lock.withLock { reopensValue = newValue } }
    }
    var reopenAsks: Int { lock.withLock { asks } }
    var holdsAnswer: Bool {
        get { lock.withLock { holds } }
        set { lock.withLock { holds = newValue } }
    }
    func stalls(_ source: URL) -> Bool { source.standardizedFileURL.path == stalling.standardizedFileURL.path }
    /// Counts the question, waits while answers are held, then answers.
    func answer() async -> Bool {
        let held: Bool = lock.withLock { asks += 1; return holds }
        if held {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    guard holds else { return true }
                    waiting.append(continuation)
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return reopens
    }
    func release() {
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            holds = false
            defer { waiting = [] }
            return waiting
        }
        for continuation in resumed { continuation.resume() }
    }
}

/// An in-memory file system whose move of one item stalls, as a live one's does when a disk stops answering, and
/// whose answer to `reopenAfterStall` the test sets.
private struct StallLatchFileSystem: FileSystem {
    let inner: InMemoryFileSystem
    let control: StallLatchControl
    func enumerate(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<[FileEntry], Error> {
        inner.enumerate(directory, options: options)
    }
    func entry(at url: URL) async throws -> FileEntry { try await inner.entry(at: url) }
    func exists(_ url: URL) async -> Bool { await inner.exists(url) }
    func isDirectory(_ url: URL, resolvingSymlinks: Bool) async -> Bool { await inner.isDirectory(url, resolvingSymlinks: resolvingSymlinks) }
    func childNames(of directory: URL) async throws -> Set<String> { try await inner.childNames(of: directory) }
    func mutationPrecondition(at source: URL) async throws -> FileMutationPrecondition { try await inner.mutationPrecondition(at: source) }
    func mutate(_ mutation: ConditionalFileMutation, source: URL, requiring precondition: FileMutationPrecondition) async throws -> URL? {
        if control.stalls(source) { throw FileSystemError.timedOut }
        return try await inner.mutate(mutation, source: source, requiring: precondition)
    }
    func copyItem(at source: URL, to destination: URL) async throws { try await inner.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) async throws { try await inner.moveItem(at: source, to: destination) }
    func replaceItem(at destination: URL, with temporary: URL, backup: URL) async throws {
        try await inner.replaceItem(at: destination, with: temporary, backup: backup)
    }
    func applyDirectoryMetadata(from source: URL, to destination: URL) async throws {
        try await inner.applyDirectoryMetadata(from: source, to: destination)
    }
    func trashItem(at url: URL) async throws -> URL? { try await inner.trashItem(at: url) }
    func removeItem(at url: URL) async throws { try await inner.removeItem(at: url) }
    func createDirectory(at url: URL) async throws { try await inner.createDirectory(at: url) }
    func createFileExclusively(at url: URL, contents: Data) async throws { try await inner.createFileExclusively(at: url, contents: contents) }
    func createSymbolicLink(at url: URL, destination: URL) async throws { try await inner.createSymbolicLink(at: url, destination: destination) }
    func createAlias(for url: URL, at destination: URL) async throws { try await inner.createAlias(for: url, at: destination) }
    func isCaseSensitive(at url: URL) async throws -> Bool { try await inner.isCaseSensitive(at: url) }
    func volumeIdentifier(for url: URL) async throws -> String { try await inner.volumeIdentifier(for: url) }
    func availableCapacity(of url: URL) async throws -> Int64 { try await inner.availableCapacity(of: url) }
    func sizeOfTree(at url: URL) -> AsyncThrowingStream<Int64, Error> { inner.sizeOfTree(at: url) }
    func makeMonitor(for directory: URL) -> any DirectoryMonitor { inner.makeMonitor(for: directory) }
    func reopenAfterStall() async -> Bool { await control.answer() }
}
