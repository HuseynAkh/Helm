// DRAFT: pending review, 2026-11-05
import Foundation
import XCTest
import HelmCore
import HelmFileSystem
@testable import HelmOperations

final class AO3WorkBudgetTests: XCTestCase {
    func testExecutedNamesBudgetAndFreshCachePerExecution() async throws {
        let fs = AO3CountingFileSystem()
        let parent = URL(fileURLWithPath: "/target")
        try await fs.base.createDirectory(at: parent)
        let steps = (0..<128).map { PlannedStep(kind: .createFile, destination: parent.appendingPathComponent("file\($0)")) }
        let executor = OperationExecutor(fileSystem: fs, origins: InMemoryTrashOrigins())
        let result = await executor.execute(OperationPlan(command: .recovery, steps: steps))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.succeededCount, 128)
        let calls = await fs.nameCalls
        XCTAssertLessThanOrEqual(calls, 1)
        let next = await executor.execute(OperationPlan(command: .recovery, steps: [PlannedStep(kind: .createFile, destination: parent.appendingPathComponent("file0"), retryKeepBoth: true)]))
        XCTAssertNil(next.error)
        XCTAssertEqual(next.outcomes.first?.destination?.lastPathComponent, "file0 2")
        let finalCalls = await fs.nameCalls
        XCTAssertLessThanOrEqual(finalCalls, 2)
    }
    func testExclusiveCollisionRefreshCostsOneAdditionalListing() async throws {
        let fs = AO3CountingFileSystem()
        let parent = URL(fileURLWithPath: "/target"), target = parent.appendingPathComponent("file")
        try await fs.base.createDirectory(at: parent)
        await fs.collideOnce(at: target)
        let result = await OperationExecutor(fileSystem: fs, origins: InMemoryTrashOrigins()).execute(
            OperationPlan(command: .recovery, steps: [PlannedStep(kind: .createFile, destination: target, retryKeepBoth: true)]))
        XCTAssertNil(result.error)
        XCTAssertEqual(result.outcomes.first?.destination?.lastPathComponent, "file 2")
        let calls = await fs.nameCalls
        XCTAssertEqual(calls, 2, "One parent plus one exclusive collision")
    }

}

private actor AO3CountingFileSystem: FileSystem {
    let base = InMemoryFileSystem()
    private(set) var nameCalls = 0
    private var collision: URL?
    func collideOnce(at url: URL) { collision = url }
    nonisolated func enumerate(_ directory: URL, options: EnumerationOptions) -> AsyncThrowingStream<[FileEntry], Error> { base.enumerate(directory, options: options) }
    func childNames(of directory: URL) async throws -> Set<String> { nameCalls += 1; return try await base.childNames(of: directory) }
    func entry(at url: URL) async throws -> FileEntry { try await base.entry(at: url) }
    func exists(_ url: URL) async -> Bool { await base.exists(url) }
    func copyItem(at source: URL, to destination: URL) async throws { try await base.copyItem(at: source, to: destination) }
    func moveItem(at source: URL, to destination: URL) async throws { try await base.moveItem(at: source, to: destination) }
    func replaceItem(at destination: URL, with temporary: URL, backup: URL) async throws { try await base.replaceItem(at: destination, with: temporary, backup: backup) }
    func applyDirectoryMetadata(from source: URL, to destination: URL) async throws { try await base.applyDirectoryMetadata(from: source, to: destination) }
    func trashItem(at url: URL) async throws -> URL? { try await base.trashItem(at: url) }
    func removeItem(at url: URL) async throws { throw FileSystemError.unsupported }
    func createDirectory(at url: URL) async throws { try await base.createDirectory(at: url) }
    func createFileExclusively(at url: URL, contents: Data) async throws {
        if collision == url {
            collision = nil
            // Simulated external writer wins admission; our attempted write has no effects.
            try await base.createFileExclusively(at: url, contents: Data([9]))
            throw FileSystemError.collision(noMutation: true)
        }
        try await base.createFileExclusively(at: url, contents: contents)
    }
    func createSymbolicLink(at url: URL, destination: URL) async throws { try await base.createSymbolicLink(at: url, destination: destination) }
    func createAlias(for url: URL, at destination: URL) async throws { try await base.createAlias(for: url, at: destination) }
    func volumeIdentifier(for url: URL) async throws -> String { try await base.volumeIdentifier(for: url) }
    func availableCapacity(of url: URL) async throws -> Int64 { try await base.availableCapacity(of: url) }
}
