// DRAFT: pending review, 2026-11-05
import Foundation
import XCTest
import HelmCore
import HelmFileSystem

final class OP2MonitorPathTests: XCTestCase {
    func testPhysicalRootAndDeletedChildMapping() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OP2-path-" + UUID().uuidString)
        let physical = root.appendingPathComponent("private/tmp/watched", isDirectory: true)
        let alias = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: physical, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: physical.deletingLastPathComponent())
        let displayed = alias.appendingPathComponent("watched", isDirectory: true)
        let canonical = try MonitorPathFilter.canonicalRoot(for: displayed)
        XCTAssertTrue(canonical.path.hasSuffix("/private/tmp/watched"))
        XCTAssertEqual(MonitorPathFilter.displayedPath(for: canonical.path + "/deleted", canonicalRoot: canonical,
            displayedRoot: displayed), displayed.path + "/deleted")
        XCTAssertEqual(MonitorPathFilter.displayedPath(for: "/private/tmp/watched/deleted",
            canonicalRoot: URL(fileURLWithPath: "/private/tmp/watched"),
            displayedRoot: URL(fileURLWithPath: "/tmp/watched")), "/tmp/watched/deleted")
        XCTAssertThrowsError(try MonitorPathFilter.canonicalRoot(for: root.appendingPathComponent("missing")))
    }
    func testFakeAliasCreationSuccess() async throws {
        let fs = InMemoryFileSystem()
        let source = URL(fileURLWithPath: "/original"), alias = URL(fileURLWithPath: "/alias")
        try await fs.createFileExclusively(at: source, contents: Data([42]))
        try await fs.createAlias(for: source, at: alias)
        let entry = try await fs.entry(at: alias)
        XCTAssertEqual(entry.kind, .alias)
        let original = try await fs.entry(at: source)
        XCTAssertEqual(original.kind, .regular)
    }
    #if os(macOS)
    func testFSEventsObservesDeletedChildUnderTmp() async throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("OP2-events-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let child = root.appendingPathComponent("child")
        try Data([1]).write(to: child)
        let monitor = FSEventsMonitor(directory: root)
        try await monitor.start()
        let deleted = expectation(description: "Deleted child retains displayed /tmp path")
        let consumer = Task {
            for await event in monitor.events {
                if case .changed(let paths) = event, paths.contains(child.path) {
                    deleted.fulfill(); return
                }
            }
        }
        // This test owns this temporary child; exercise the native deletion event.
        do { try FileManager.default.removeItem(at: child) }
        catch {
            await monitor.stop()
            consumer.cancel()
            await consumer.value
            throw error
        }
        await fulfillment(of: [deleted], timeout: 8)
        await monitor.stop()
        consumer.cancel()
        await consumer.value
    }
    #endif
}
