// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import Foundation
import HelmCore
@testable import HelmFileSystem
import HelmOperations

final class F16CancellationTests: XCTestCase {
    func testInitialUndoTokenReadCancellationIsClean() async throws {
        try await checkUndoCancellation(initial: true)
    }
    func testSecondInverseTokenReadCancellationRetainsRecoverableFirstMove() async throws {
        try await checkUndoCancellation(initial: false)
    }
    func testMoveAdmissionCancellationHasNoEffects() async throws {
        try await checkAdmissionCancellation(kind: .move)
    }
    func testTrashAdmissionCancellationHasNoEffects() async throws {
        try await checkAdmissionCancellation(kind: .trash)
    }
    private func checkAdmissionCancellation(kind: PlannedStep.Kind) async throws {
        let fs = InMemoryFileSystem(), origins = F16OriginSpy()
        let source = URL(fileURLWithPath: "/source"), output = URL(fileURLWithPath: "/output")
        try await fs.createFileExclusively(at: source, contents: Data([4]))
        let before = try await fs.entry(at: source)
        let gate = F16ReadGate(), entered = expectation(description: "conditional admission")
        let completed = expectation(description: "conditional cancellation completed")
        let adapter = F16ReadFileSystem(fs: fs, source: source, read: 0, gate: gate, entered: { entered.fulfill() })
        let executor = OperationExecutor(fileSystem: adapter, origins: origins)
        let task = Task {
            let result = await executor.execute(OperationPlan(command: .recovery, steps: [
                PlannedStep(kind: kind, source: source, destination: kind == .move ? output : nil)]))
            completed.fulfill()
            return result
        }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        await gate.release()
        await fulfillment(of: [completed], timeout: 5)
        let result = await task.value
        XCTAssertEqual(result.error, .cancelled)
        XCTAssertEqual(result.succeededCount, 0)
        XCTAssertFalse(result.outcomes.contains(where: \.requiresReconciliation))
        let after = try await fs.entry(at: source)
        let bytes = try await fs.storedContents(at: source)
        let names = try await fs.childNames(of: URL(fileURLWithPath: "/"))
        XCTAssertEqual(before, after)
        XCTAssertEqual(bytes, Data([4]))
        XCTAssertEqual(names, ["source"])
        let recorded = await origins.items
        XCTAssertTrue(recorded.isEmpty)
        XCTAssertNil(result.outcomes.first?.destinationEvidence)
        let next = await executor.execute(OperationPlan(command: .recovery, steps: [
            PlannedStep(kind: .createFile, destination: output)]))
        XCTAssertNil(next.error)
    }
    private func checkUndoCancellation(initial: Bool) async throws {
        let fs = InMemoryFileSystem()
        let a = URL(fileURLWithPath: "/a"), b = URL(fileURLWithPath: "/b")
        let x = URL(fileURLWithPath: "/x"), y = URL(fileURLWithPath: "/y")
        try await fs.createFileExclusively(at: a, contents: Data([1]))
        try await fs.createFileExclusively(at: b, contents: Data([2]))
        let forwardExecutor = OperationExecutor(fileSystem: fs, origins: InMemoryTrashOrigins())
        let forward = await forwardExecutor.execute(OperationPlan(command: .recovery, steps: [
            PlannedStep(kind: .move, source: a, destination: x),
            PlannedStep(kind: .move, source: b, destination: y)]))
        XCTAssertNil(forward.error)
        let stored = await forwardExecutor.journal.entry(forward.id)
        let inverse = UndoPlanner.inverse(of: try XCTUnwrap(stored), recordedOrigins: [:])
        let before = try await fs.entry(at: x)
        let entered = expectation(description: "token read entered")
        let completed = expectation(description: "execution completed")
        let gate = F16ReadGate()
        let adapter = F16ReadFileSystem(fs: fs, source: x, read: initial ? 1 : 3,
                                       gate: gate, entered: { entered.fulfill() })
        let executor = OperationExecutor(fileSystem: adapter, origins: InMemoryTrashOrigins())
        let task = Task {
            let result = await executor.execute(inverse)
            completed.fulfill()
            return result
        }
        await fulfillment(of: [entered], timeout: 5)
        task.cancel()
        await gate.release()
        await fulfillment(of: [completed], timeout: 5)
        let result = await task.value
        XCTAssertEqual(result.error, .cancelled)
        XCTAssertEqual(result.succeededCount, initial ? 0 : 1)
        XCTAssertFalse(result.outcomes.contains(where: \.requiresReconciliation))
        let calls = await adapter.mutations
        XCTAssertEqual(calls, initial ? [] : [y])
        let after = try await fs.entry(at: x)
        let bytes = try await fs.storedContents(at: x)
        let aExists = await fs.exists(a)
        XCTAssertEqual(after, before)
        XCTAssertEqual(bytes, Data([1]))
        XCTAssertFalse(aExists)
        if !initial {
            let partial = await executor.journal.entry(result.id)
            let recovery = UndoPlanner.inverse(of: try XCTUnwrap(partial), recordedOrigins: [:])
            XCTAssertTrue(recovery.isExecutable)
            XCTAssertEqual(recovery.steps.count, 1)
            let recovered = await executor.execute(recovery)
            XCTAssertNil(recovered.error)
            XCTAssertEqual(recovered.succeededCount, 1)
            let restored = try await fs.storedContents(at: y)
            XCTAssertEqual(restored, Data([2]))
        }
        let next = await executor.execute(OperationPlan(command: .recovery, steps: [
            PlannedStep(kind: .createFile, destination: URL(fileURLWithPath: "/next"))]))
        XCTAssertNil(next.error)
    }
}
private actor F16ReadGate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private actor F16ReadFileSystem: FileSystem {
    let fs: InMemoryFileSystem
    let source: URL
    let read: Int
    let gate: F16ReadGate
    let entered: @Sendable () -> Void
    var reads = 0
    var mutations: [URL] = []
    init(fs: InMemoryFileSystem, source: URL, read: Int, gate: F16ReadGate, entered: @escaping @Sendable () -> Void) {
        self.fs = fs; self.source = source; self.read = read; self.gate = gate; self.entered = entered
    }
    func entry(at url: URL) async throws -> FileEntry {
        if url == source {
            reads += 1
            if reads == read {
                entered()
                await gate.wait()
                try Task.checkCancellation()
            }
        }
        return try await fs.entry(at: url)
    }
    func mutate(_ mutation: ConditionalFileMutation, source: URL, requiring evidence: FileMutationPrecondition) async throws -> URL? {
        mutations.append(source)
        if read == 0 { entered(); await gate.wait() }
        return try await fs.mutate(mutation, source: source, requiring: evidence)
    }
    nonisolated func enumerate(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<[FileEntry], Error> { fs.enumerate(directory, options: options) }
    func exists(_ url: URL) async -> Bool { await fs.exists(url) }
    func childNames(of directory: URL) async throws -> Set<String> { try await fs.childNames(of: directory) }
    func copyItem(at source: URL, to destination: URL) async throws { try await fs.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) async throws { try await fs.moveItem(at: source, to: destination) }
    func replaceItem(at destination: URL, with temporary: URL, backup: URL) async throws { try await fs.replaceItem(at: destination, with: temporary, backup: backup) }
    func applyDirectoryMetadata(from source: URL, to destination: URL) async throws { try await fs.applyDirectoryMetadata(from: source, to: destination) }
    func trashItem(at url: URL) async throws -> URL? { try await fs.trashItem(at: url) }
    func removeItem(at url: URL) async throws { try await fs.removeItem(at: url) }
    func createDirectory(at url: URL) async throws { try await fs.createDirectory(at: url) }
    func createFileExclusively(at url: URL, contents: Data) async throws { try await fs.createFileExclusively(at: url, contents: contents) }
    func createSymbolicLink(at url: URL, destination: URL) async throws { try await fs.createSymbolicLink(at: url, destination: destination) }
    func createAlias(for url: URL, at destination: URL) async throws { try await fs.createAlias(for: url, at: destination) }
    func volumeIdentifier(for url: URL) async throws -> String { try await fs.volumeIdentifier(for: url) }
    func availableCapacity(of url: URL) async throws -> Int64 { try await fs.availableCapacity(of: url) }
}

private actor F16OriginSpy: TrashOriginRecording {
    var items: [TrashedItem] = []
    func record(_ items: [TrashedItem]) { self.items.append(contentsOf: items) }
    func originalURL(forTrashed url: URL) -> URL? { items.first { $0.trashedURL == url }?.originalURL }
}
