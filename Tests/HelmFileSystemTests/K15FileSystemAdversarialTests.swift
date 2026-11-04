// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmFileSystem

final class K15FileSystemAdversarialTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/folder")
    private func listing(_ fs: InMemoryFileSystem, batchSize: Int, count: Int) async throws {
        try await fs.createDirectory(at: root)
        try await fs.seedFiles(in: root, count: count)
        var ids: Set<ItemID> = []
        var total = 0
        for try await batch in fs.enumerate(root, options: EnumerationOptions(batchSize: batchSize)) {
            XCTAssertLessThanOrEqual(batch.count, max(1, batchSize)); XCTAssertFalse(batch.isEmpty)
            total += batch.count; ids.formUnion(batch.map(\.id))
        }
        XCTAssertEqual(total, count); XCTAssertEqual(ids.count, count)
    }
    /// F-035/B-010: zero batch size is bounded and cannot hang enumeration.
    func testZeroBatchSize() async throws { try await listing(InMemoryFileSystem(), batchSize: 0, count: 7) }
    /// F-035/B-010: negative batch size is bounded and cannot trap.
    func testNegativeBatchSize() async throws { try await listing(InMemoryFileSystem(), batchSize: -100, count: 7) }
    /// F-035: exact batch boundaries never duplicate a row.
    func testExactBatchBoundary() async throws { try await listing(InMemoryFileSystem(), batchSize: 8, count: 16) }
    /// F-035: remainder batches retain the last item.
    func testRemainderBatchBoundary() async throws { try await listing(InMemoryFileSystem(), batchSize: 8, count: 17) }
    /// F-035/B-010: huge-folder identities remain unique across streamed batches.
    func testHugeFolderBatchIntegrity() async throws { try await listing(InMemoryFileSystem(), batchSize: 127, count: 25000) }
    /// F-035: empty folders terminate without emitting phantom entries.
    func testEmptyFolderEnumeration() async throws { try await listing(InMemoryFileSystem(), batchSize: 1, count: 0) }
    /// B-039: canonically equivalent Unicode names collide on the fake filesystem.
    func testUnicodeNormalizationCollision() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createFileExclusively(at: URL(fileURLWithPath: "/café"), contents: Data([1, 2]))
        do {
            try await fs.createFileExclusively(at: URL(fileURLWithPath: "/cafe\u{301}"), contents: Data([3]))
            XCTFail("B-039: normalized duplicate accepted")
        } catch {}
        let retained = try await fs.entry(at: URL(fileURLWithPath: "/cafe\u{301}"))
        XCTAssertEqual(retained.size, 2)
    }
    /// F-015/B-039: lexical dot components identify the same file.
    func testDotDotLookup() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        try await fs.createFileExclusively(at: root.appendingPathComponent("file"), contents: Data([1]))
        let entry = try await fs.entry(at: URL(fileURLWithPath: "/folder/../folder/./file"))
        XCTAssertEqual(entry.size, 1)
    }
    /// F-015: trailing directory slash does not alter membership.
    func testTrailingSlashListing() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        try await fs.createFileExclusively(at: root.appendingPathComponent("file"), contents: Data())
        let names = try await fs.childNames(of: URL(fileURLWithPath: "/folder/"))
        XCTAssertEqual(names, ["file"])
    }
    /// B-039: a symlink to itself remains a leaf and cannot recurse.
    func testSelfSymlinkLoop() async throws { try await loop(length: 1) }
    /// B-039: multi-node symlink loops terminate safely.
    func testLongSymlinkLoop() async throws { try await loop(length: 32) }
    private func loop(length: Int) async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        for index in 0..<length {
            try await fs.createSymbolicLink(at: root.appendingPathComponent("link\(index)"),
                                            destination: root.appendingPathComponent("link\((index + 1) % length)"))
        }
        var count = 0
        for try await batch in fs.enumerate(root, options: EnumerationOptions()) {
            count += batch.count; XCTAssertTrue(batch.allSatisfy { $0.kind == .danglingSymlink })
        }
        XCTAssertEqual(count, length)
        var size: Int64 = -1
        for try await value in fs.sizeOfTree(at: root) { size = value }
        XCTAssertEqual(size, 0)
    }
    /// F-053/B-042: same-basename trash entries preserve all original payload sizes.
    func testRepeatedTrashCollisionRetainsAllItems() async throws {
        let fs = InMemoryFileSystem()
        var destinations: Set<URL> = []
        for count in 1...20 {
            let file = URL(fileURLWithPath: "/same")
            try await fs.createFileExclusively(at: file, contents: Data(repeating: 1, count: count))
            let trashed = try await fs.trashItem(at: file)
            let destination = try XCTUnwrap(trashed)
            XCTAssertTrue(destinations.insert(destination).inserted)
            let entry = try await fs.entry(at: destination); XCTAssertEqual(entry.size, Int64(count))
        }
        let names = try await fs.childNames(of: URL(fileURLWithPath: "/.Trash")); XCTAssertEqual(names.count, 20)
    }
    /// B-017: parent permission failure cannot masquerade as an empty child listing.
    func testAncestorDenialIsThrown() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        let child = root.appendingPathComponent("child")
        try await fs.createDirectory(at: child)
        await fs.setFailure(.permissionDenied, at: root)
        do {
            for try await _ in fs.enumerate(child, options: EnumerationOptions()) {}
            XCTFail("B-017: denied enumeration succeeded")
        } catch { XCTAssertEqual(error as? FileSystemError, .permissionDenied) }
    }
    /// F-061: metadata cancellation is checked before even a missing-path lookup.
    func testCancelledMissingMetadata() async {
        let fs = InMemoryFileSystem()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fs.entry(at: URL(fileURLWithPath: "/missing"))
        }
        do { _ = try await task.value; XCTFail("Cancellation ignored") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }
    /// F-052/B-039: copying a symlink preserves a leaf without duplicating its target tree.
    func testCopySymlinkDoesNotTraverseTarget() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        try await fs.seedFiles(in: root, count: 100)
        let link = URL(fileURLWithPath: "/link"), copy = URL(fileURLWithPath: "/copy")
        try await fs.createSymbolicLink(at: link, destination: root)
        try await fs.copyItem(at: link, to: copy)
        let entry = try await fs.entry(at: copy); XCTAssertEqual(entry.kind, .symlinkToDirectory)
        try await fs.removeItem(at: copy)
        let names = try await fs.childNames(of: root); XCTAssertEqual(names.count, 100)
    }
}
