import Foundation
import XCTest
import HelmCore
import HelmFileSystem
import HelmOperations

/// With downloads off, a copy of an item that isn't downloaded is refused before anything is read or written. The
/// executor then has nothing to be unsure of: the item is one failure that can be skipped, the rest of the command
/// still runs, and a later command isn't held up.
final class DownloadsOffCopyTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/home/cloud", isDirectory: true)
    private var backup: URL { folder.appendingPathComponent("Backup", isDirectory: true) }

    func testACopyOfAnItemNotDownloadedIsSkippedWithNothingReadOrLeftUnsure() async throws {
        let memory = InMemoryFileSystem()
        for path in [URL(fileURLWithPath: "/home", isDirectory: true), folder, backup] { try await memory.createDirectory(at: path) }
        let clip = folder.appendingPathComponent("clip.mov"), notes = folder.appendingPathComponent("notes.txt")
        try await memory.createFileExclusively(at: clip, contents: Data("frames".utf8))
        try await memory.createFileExclusively(at: notes, contents: Data("words".utf8))
        await memory.setCloudAvailability(.evicted, at: clip)
        let executor = OperationExecutor(fileSystem: memory, origins: InMemoryTrashOrigins())

        let result = try await DatalessGuard.off { () -> OperationResult in
            let command = Command.copy(sources: [clip, notes], destinationDirectory: backup)
            let context = try await PlanningContextBuilder(fileSystem: memory).build(sources: [clip, notes], destinations: [backup])
            let plan = OperationPlanner.plan(command, context: context)
            XCTAssertTrue(plan.isExecutable)
            return await executor.execute(plan, decide: { _ in .skip })
        }

        let failed = result.outcomes.filter { !$0.succeeded && $0.step.source == clip }
        XCTAssertFalse(failed.isEmpty, "the clip wasn't copied")
        XCTAssertFalse(result.outcomes.contains(where: \.requiresReconciliation), "nothing was left unsure")
        XCTAssertEqual(result.succeededItemCount, 1, "the rest of the command still ran")
        let copiedClip = await memory.exists(backup.appendingPathComponent("clip.mov"))
        let copiedNotes = await memory.exists(backup.appendingPathComponent("notes.txt"))
        XCTAssertFalse(copiedClip)
        XCTAssertTrue(copiedNotes)
        let reads = await memory.reads
        XCTAssertFalse(reads.contains(clip.path), "nothing of the clip was read: \(reads)")

        // A later command runs as usual.
        let later = try await DatalessGuard.off { () -> OperationResult in
            let command = Command.createFolder(parent: folder, name: try XCTUnwrap(ValidFileName("Later")))
            let context = try await PlanningContextBuilder(fileSystem: memory).build(sources: [], destinations: [folder])
            return await executor.execute(OperationPlanner.plan(command, context: context))
        }
        XCTAssertNil(later.error)
    }
}
