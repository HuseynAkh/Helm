// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmFileSystem

// F-035/F-042/B-073: cache and targeted refresh must agree with fresh enumeration.
final class T2DirectoryLoaderTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/t2")
    private func fixture() async throws -> (InMemoryFileSystem, DirectoryLoader) {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        for name in ["file10", "file2", ".hidden"] {
            try await fs.createFileExclusively(at: root.appendingPathComponent(name), contents: Data([1]))
        }
        return (fs, DirectoryLoader(fileSystem: fs))
    }
    func testCachedAndFreshOrderingAgree() async throws {
        let (_, loader) = try await fixture()
        let first = try await loader.snapshot(.directory(root))
        let cached = try await loader.snapshot(.directory(root))
        let fresh = try await loader.snapshot(.directory(root), options: LoadOptions(useCache: false))
        XCTAssertEqual(first.map(\.name), ["file2", "file10"])
        XCTAssertEqual(cached, first)
        XCTAssertEqual(fresh, first)
    }
    func testHiddenCachePartition() async throws {
        let (_, loader) = try await fixture()
        let shown = try await loader.snapshot(.directory(root), options: LoadOptions(showHidden: true))
        let hidden = try await loader.snapshot(.directory(root))
        XCTAssertEqual(shown.count, 3)
        XCTAssertEqual(hidden.count, 2)
    }
    func testCacheDoesNotBypassPermissionFailure() async throws {
        let (fs, loader) = try await fixture()
        _ = try await loader.snapshot(.directory(root))
        await fs.setFailure(.permissionDenied, at: root)
        do { _ = try await loader.snapshot(.directory(root)); XCTFail("Cache bypassed access check") }
        catch { XCTAssertEqual(error as? FileSystemError, .permissionDenied) }
    }
    func testRefreshAddsDirectChild() async throws {
        let (fs, loader) = try await fixture()
        let before = try await loader.snapshot(.directory(root))
        let added = root.appendingPathComponent("file1")
        try await fs.createFileExclusively(at: added, contents: Data())
        let after = try await loader.refresh(location: .directory(root), changed: [added.path], current: before)
        XCTAssertEqual(after.map(\.name), ["file1", "file2", "file10"])
    }
    func testRefreshRemovesMissingDirectChild() async throws {
        let (fs, loader) = try await fixture()
        let before = try await loader.snapshot(.directory(root))
        let removed = root.appendingPathComponent("file2")
        try await fs.removeItem(at: removed)
        let after = try await loader.refresh(location: .directory(root), changed: [removed.path], current: before)
        XCTAssertEqual(after.map(\.name), ["file10"])
    }
    func testRefreshIgnoresGrandchildrenAndOtherRoots() async throws {
        let (_, loader) = try await fixture()
        let before = try await loader.snapshot(.directory(root))
        let after = try await loader.refresh(location: .directory(root), changed: ["/elsewhere/x", "/t2/sub/file"], current: before)
        XCTAssertEqual(after, before)
    }
    func testRootChangeReconcilesEntireListing() async throws {
        let (fs, loader) = try await fixture()
        let before = try await loader.snapshot(.directory(root))
        try await fs.removeItem(at: root.appendingPathComponent("file2"))
        try await fs.createFileExclusively(at: root.appendingPathComponent("file3"), contents: Data())
        let after = try await loader.refresh(location: .directory(root), changed: [root.path], current: before)
        XCTAssertEqual(after.map(\.name), ["file3", "file10"])
    }
    func testRefreshPermissionErrorIsNotDeletion() async throws {
        let (fs, loader) = try await fixture()
        let before = try await loader.snapshot(.directory(root))
        let path = root.appendingPathComponent("file2")
        await fs.setFailure(.permissionDenied, at: path)
        do { _ = try await loader.refresh(location: .directory(root), changed: [path.path], current: before); XCTFail("Access failure treated as deletion") }
        catch { XCTAssertEqual(error as? FileSystemError, .permissionDenied) }
    }
    func testPrecancelledSnapshotRefusesWork() async throws {
        let (_, loader) = try await fixture()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await loader.snapshot(.directory(root)); XCTFail("Cancellation ignored") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        await task.value
    }
    func testVirtualSnapshotRefused() async throws {
        let (_, loader) = try await fixture()
        do { _ = try await loader.snapshot(.recent); XCTFail("Virtual location enumerated as directory") }
        catch { XCTAssertEqual(error as? FileSystemError, .unsupported) }
    }
}
