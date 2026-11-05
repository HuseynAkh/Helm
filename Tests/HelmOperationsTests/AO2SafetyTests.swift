// DRAFT: pending review, 2026-11-04
import XCTest
import Foundation
import HelmCore
@testable import HelmFileSystem
import HelmOperations

final class AO2OperationSafetyTests: XCTestCase {
    func testCancelledFinalCopyKeepsEvidenceAndCanBeUndone() async throws {
        let fs = InMemoryFileSystem()
        let source = URL(fileURLWithPath: "/source"), output = URL(fileURLWithPath: "/output")
        try await fs.createFileExclusively(at: source, contents: Data([1]))
        let entered = expectation(description: "copy started")
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let executor = OperationExecutor(fileSystem: fs, copier: AO2GatedCopier(
            fs: fs, io: IOExecutor(timeout: 5), gate: gate, entered: { entered.fulfill() }))
        let plan = OperationPlan(command: .recovery,
            steps: [PlannedStep(kind: .copy, source: source, destination: output)])
        let task = Task { await executor.execute(plan) }
        await fulfillment(of: [entered], timeout: 2)
        task.cancel()
        gate.signal()
        let result = await task.value
        XCTAssertNil(result.error)
        XCTAssertEqual(result.succeededCount, 1)
        XCTAssertNotNil(try XCTUnwrap(result.outcomes.first).destinationEvidence)
        let entry = await executor.journal.entry(result.id)
        let inverse = UndoPlanner.inverse(of: try XCTUnwrap(entry), recordedOrigins: [:])
        XCTAssertTrue(inverse.isExecutable)
        let undone = await executor.execute(inverse)
        XCTAssertNil(undone.error)
        XCTAssertEqual(undone.succeededCount, 1)
    }

    func testInverseMismatchAfterProgressHasNoUncertainMutation() async throws {
        let fs = InMemoryFileSystem(), executor = OperationExecutor(fileSystem: fs)
        let output = URL(fileURLWithPath: "/output")
        let forward = await executor.execute(OperationPlan(command: .recovery,
            steps: [PlannedStep(kind: .createFile, destination: output, contents: Data([1]))]))
        XCTAssertNil(forward.error)
        let stored = await executor.journal.entry(forward.id)
        let inverse = UndoPlanner.inverse(of: try XCTUnwrap(stored), recordedOrigins: [:])
        let result = await executor.execute(inverse, progress: { progress in
            if progress.currentName != nil {
                try? await fs.removeItem(at: output)
                try? await fs.createFileExclusively(at: output, contents: Data([2, 3]))
            }
        })
        XCTAssertEqual(result.error, .sourceChanged(output))
        XCTAssertEqual(result.succeededCount, 0)
        XCTAssertFalse(try XCTUnwrap(result.outcomes.first).requiresReconciliation)
    }

    func testTreeUndoWithJournalEvidenceRefusesEditedDescendants() async throws {
        for kind: PlannedStep.Kind in [.copy, .move, .createDirectory] {
            let fs = InMemoryFileSystem(), executor = OperationExecutor(fileSystem: fs)
            let source = URL(fileURLWithPath: "/source"), output = URL(fileURLWithPath: "/output")
            try await fs.createDirectory(at: source)
            try await fs.createDirectory(at: source.appendingPathComponent("nested"))
            let sourceLeaf = source.appendingPathComponent("nested/leaf")
            try await fs.createFileExclusively(at: sourceLeaf, contents: Data([1]))
            let plan = OperationPlan(command: .recovery, steps: [PlannedStep(kind: kind,
                source: kind == .createDirectory ? nil : source, destination: output)])
            let result = await executor.execute(plan)
            XCTAssertNil(result.error)
            XCTAssertEqual(result.succeededCount, 1)
            let stored = await executor.journal.entry(result.id)
            let inverse = UndoPlanner.inverse(of: try XCTUnwrap(stored), recordedOrigins: [:])
            XCTAssertTrue(inverse.isExecutable)
            XCTAssertNotNil(inverse.expectedEvidence[output])
            XCTAssertEqual(inverse.expectedKinds[output], .directory)
            // Change a descendant without changing the directory root token.
            let rootToken = try await fs.entry(at: output).changeToken
            let savedMetadata = URL(fileURLWithPath: "/saved-metadata")
            if kind == .createDirectory {
                try await fs.createDirectory(at: savedMetadata)
                try await fs.applyDirectoryMetadata(from: output, to: savedMetadata)
            }
            let leaf = output.appendingPathComponent(kind == .createDirectory ? "added" : "nested/leaf")
            if kind != .createDirectory { try await fs.removeItem(at: leaf) }
            try await fs.createFileExclusively(at: leaf, contents: Data([9, 8]))
            // A writer may restore the root timestamp after adding a child. Identity stays intact.
            if kind == .createDirectory { try await fs.applyDirectoryMetadata(from: savedMetadata, to: output) }
            let changedRootToken = try await fs.entry(at: output).changeToken
            XCTAssertEqual(changedRootToken, rootToken)
            let before = try await inventory(fs)
            let undone = await executor.execute(inverse)
            XCTAssertEqual(undone.error, .verificationUnavailable)
            XCTAssertEqual(undone.succeededCount, 0)
            let after = try await inventory(fs)
            XCTAssertEqual(after, before)
        }
    }

    func testCancelledQueuedCreateDoesNotQuarantineOperationExecutor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for directory in [false, true] {
            let io = IOExecutor(maxConcurrentOperations: 1, timeout: 5)
            let started = expectation(description: "create reached provider")
            let fs = AO2CreateFileSystem(live: LiveFileSystem(executor: io), entered: { started.fulfill() })
            let executor = OperationExecutor(fileSystem: fs)
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let blocked = expectation(description: "queue occupied")
            let blocker = Task { try await io.run { blocked.fulfill(); gate.wait() } }
            await fulfillment(of: [blocked], timeout: 2)
            let output = root.appendingPathComponent(directory ? "folder" : "file")
            let plan = OperationPlan(command: .recovery, steps: [PlannedStep(
                kind: directory ? .createDirectory : .createFile, destination: output)])
            let task = Task { await executor.execute(plan) }
            await fulfillment(of: [started], timeout: 2)
            task.cancel()
            let result = await task.value
            XCTAssertEqual(result.error, .cancelled)
            XCTAssertFalse(try XCTUnwrap(result.outcomes.first).requiresReconciliation)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            gate.signal()
            try await blocker.value
            let next = await executor.execute(OperationPlan(command: .recovery, steps: []))
            XCTAssertNotEqual(next.error, .busy)
        }
    }

    private struct PhysicalEntry: Equatable {
        let entry: FileEntry
        let contents: Data
    }
    private func inventory(_ fs: InMemoryFileSystem) async throws -> [String: PhysicalEntry] {
        var directories = [URL(fileURLWithPath: "/")]
        var result: [String: PhysicalEntry] = [:]
        while let directory = directories.popLast() {
            for try await batch in fs.enumerate(directory, options: EnumerationOptions(includeHidden: true)) {
                for entry in batch {
                    result[entry.url.path] = PhysicalEntry(entry: entry, contents: try await fs.storedContents(at: entry.url))
                    if entry.kind == .directory { directories.append(entry.url) }
                }
            }
        }
        return result
    }
}

// Read-only preflights are immediate; only the actual create uses the blocked live queue.
private struct AO2CreateFileSystem: FileSystem {
    let live: LiveFileSystem
    let entered: @Sendable () -> Void
    func entry(at url: URL) async throws -> FileEntry { FileEntry(url: url, kind: .directory) }
    func childNames(of directory: URL) async throws -> Set<String> { [] }
    func exists(_ url: URL) async -> Bool { false }
    func enumerate(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<[FileEntry], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func createDirectory(at url: URL) async throws { entered(); try await live.createDirectory(at: url) }
    func createFileExclusively(at url: URL, contents: Data) async throws { entered(); try await live.createFileExclusively(at: url, contents: contents) }
    func copyItem(at source: URL, to destination: URL) async throws { throw FileSystemError.unsupported }
    func moveItem(at source: URL, to destination: URL) async throws { throw FileSystemError.unsupported }
    func replaceItem(at destination: URL, with temporary: URL, backup: URL) async throws { throw FileSystemError.unsupported }
    func applyDirectoryMetadata(from source: URL, to destination: URL) async throws { throw FileSystemError.unsupported }
    func trashItem(at url: URL) async throws -> URL? { throw FileSystemError.unsupported }
    func removeItem(at url: URL) async throws { throw FileSystemError.unsupported }
    func createSymbolicLink(at url: URL, destination: URL) async throws { throw FileSystemError.unsupported }
    func createAlias(for url: URL, at destination: URL) async throws { throw FileSystemError.unsupported }
    func volumeIdentifier(for url: URL) async throws -> String { "test" }
    func availableCapacity(of url: URL) async throws -> Int64 { 1000 }
}

private struct AO2GatedCopier: FileCopier {
    let fs: InMemoryFileSystem
    let io: IOExecutor
    let gate: DispatchSemaphore
    let entered: @Sendable () -> Void
    func copy(from source: URL, to destination: URL) async throws {
        try await copy(from: source, to: destination, requiring: fs.mutationPrecondition(at: source))
    }
    func copy(from source: URL, to destination: URL, requiring evidence: FileMutationPrecondition) async throws {
        try await Task.detached {
            try await io.run { entered(); gate.wait() }
            _ = try await fs.mutate(.copy(to: destination), source: source, requiring: evidence)
        }.value
    }
}
