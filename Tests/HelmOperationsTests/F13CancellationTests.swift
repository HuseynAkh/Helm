// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import Foundation
import HelmCore
import HelmFileSystem
import HelmOperations

final class F13CancellationTests: XCTestCase {
    func testGatedCancellationBeforeAdmissionLeavesExecutorUsable() async throws {
        let fs = InMemoryFileSystem(), source = URL(fileURLWithPath: "/source")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        let gate = F13Gate(), entered = expectation(description: "Awaiting admission")
        let executor = OperationExecutor(fileSystem: fs, copier: F13GatedCopier(fs: fs, gate: gate, entered: { entered.fulfill() }))
        let task = Task { await executor.execute(copyPlan(source)) }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        await gate.release()
        let result = await task.value
        XCTAssertEqual(result.error, .cancelled)
        XCTAssertFalse(try XCTUnwrap(result.outcomes.first).requiresReconciliation)
        let exists = await fs.exists(URL(fileURLWithPath: "/output"))
        XCTAssertFalse(exists)
        let next = await executor.execute(createPlan())
        XCTAssertNil(next.error)
    }
    func testReadOnlyValidationCancellationDoesNotQuarantine() async throws {
        let fs = InMemoryFileSystem(), source = URL(fileURLWithPath: "/source")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        let executor = OperationExecutor(fileSystem: F13ReadCancellation(fs: fs, source: source))
        let result = await executor.execute(copyPlan(source))
        XCTAssertEqual(result.error, .cancelled)
        XCTAssertFalse(try XCTUnwrap(result.outcomes.first).requiresReconciliation)
        let exists = await fs.exists(URL(fileURLWithPath: "/output"))
        XCTAssertFalse(exists)
        let next = await executor.execute(createPlan())
        XCTAssertNil(next.error)
    }
    func testOrdinaryPrimitiveCancellationStillQuarantines() async throws {
        let fs = InMemoryFileSystem(), source = URL(fileURLWithPath: "/source")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        let executor = OperationExecutor(fileSystem: fs, copier: F13UncertainCopier())
        let result = await executor.execute(copyPlan(source))
        XCTAssertEqual(result.error, .cancelled)
        XCTAssertTrue(try XCTUnwrap(result.outcomes.first).requiresReconciliation)
        let next = await executor.execute(createPlan())
        XCTAssertEqual(next.error, .busy)
    }
    private func copyPlan(_ source: URL) -> OperationPlan {
        OperationPlan(command: .recovery, steps: [PlannedStep(kind: .copy, source: source, destination: URL(fileURLWithPath: "/output"))])
    }
    private func createPlan() -> OperationPlan {
        OperationPlan(command: .recovery, steps: [PlannedStep(kind: .createFile, destination: URL(fileURLWithPath: "/next"))])
    }
}
private actor F13Gate {
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private struct F13GatedCopier: FileCopier {
    let fs: InMemoryFileSystem
    let gate: F13Gate
    let entered: @Sendable () -> Void
    func copy(from source: URL, to destination: URL) async throws { XCTFail("Unconditional copy") }
    func copy(from source: URL, to destination: URL, requiring evidence: FileMutationPrecondition) async throws {
        entered()
        await gate.wait()
        _ = try await fs.mutate(.copy(to: destination), source: source, requiring: evidence)
    }
}
private struct F13UncertainCopier: FileCopier {
    func copy(from source: URL, to destination: URL) async throws { throw CancellationError() }
    func copy(from source: URL, to destination: URL, requiring evidence: FileMutationPrecondition) async throws { throw CancellationError() }
}
private actor F13ReadCancellation: FileSystem {
    let fs: InMemoryFileSystem
    let source: URL
    var reads = 0
    init(fs: InMemoryFileSystem, source: URL) { self.fs = fs; self.source = source }
    func entry(at url: URL) async throws -> FileEntry {
        if url == source {
            reads += 1
            if reads == 2 { throw CancellationError() }
        }
        return try await fs.entry(at: url)
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
