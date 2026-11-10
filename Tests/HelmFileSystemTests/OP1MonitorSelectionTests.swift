// DRAFT: pending review, 2026-11-05
import Foundation
import XCTest
import HelmCore
import HelmTestKit
@testable import HelmFileSystem

/// FB1-10 and FB1-19.
final class OP1MonitorSelectionTests: XCTestCase {
    func testPollingDelayBacksOffForSlowReadsOnly() {
        XCTAssertEqual(PollingMonitor.nextDelay(interval: 3_000, lastRead: 100), 3_000, "A fast read keeps the interval")
        XCTAssertEqual(PollingMonitor.nextDelay(interval: 3_000, lastRead: 1_000), 4_000, "Reads stay near a fifth of wall time")
        XCTAssertEqual(PollingMonitor.nextDelay(interval: 3_000, lastRead: UInt64.max), UInt64.max, "Overflow saturates")
    }
    func testRemoteVolumeSelectsPolling() async throws {
        let fs = InMemoryFileSystem(), root = URL(fileURLWithPath: "/share")
        try await fs.createDirectory(at: root)
        let monitor = FallbackMonitor(directory: root, fileSystem: fs, isLocalVolume: { _ in false })
        try await monitor.start()
        let mechanism = await monitor.mechanism
        XCTAssertEqual(mechanism, "polling")
        await monitor.stop()
    }
    func testCoalescerReportsPendingOnlyWhileChangesWait() {
        let clock = FakeClock()
        var coalescer = EventCoalescer(clock: clock)
        XCTAssertFalse(coalescer.hasPending)
        XCTAssertTrue(coalescer.receive(.changed(paths: ["/a"])).isEmpty)
        XCTAssertTrue(coalescer.hasPending)
        clock.advance(by: 1)
        XCTAssertEqual(coalescer.flushIfDue().count, 1)
        XCTAssertFalse(coalescer.hasPending)
    }
    #if os(macOS)
    func testAliasCreationRefusesAnOccupiedDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("helm-op1-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("source")
        try Data("source".utf8).write(to: source)
        let occupied = directory.appendingPathComponent("occupied")
        try Data("keep".utf8).write(to: occupied)
        do {
            try await LiveFileSystem().createAlias(for: source, at: occupied)
            XCTFail("An existing destination must not be overwritten")
        } catch { XCTAssertEqual(error as? FileSystemError, .collision(noMutation: true)) }
        XCTAssertEqual(try Data(contentsOf: occupied), Data("keep".utf8))
    }
    #endif
}
