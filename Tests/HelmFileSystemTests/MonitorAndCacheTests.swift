import XCTest
import Foundation
import HelmCore
import HelmFileSystem
import HelmTestKit

final class MonitorAndCacheTests: XCTestCase {
    func testCoalescerQuietAndSustainedWindows() {
        let clock = FakeClock()
        var coalescer = EventCoalescer(clock: clock)
        XCTAssertEqual(coalescer.receive(.changed(paths: ["a"])), [])
        clock.advance(by: 0.2)
        XCTAssertEqual(coalescer.receive(.changed(paths: ["b"])), [])
        clock.advance(by: 0.26)
        XCTAssertEqual(coalescer.flushIfDue(), [.changed(paths: ["a", "b"])])
        for _ in 0..<5 {
            XCTAssertEqual(coalescer.receive(.changed(paths: ["c"])), [])
            clock.advance(by: 0.2)
        }
        XCTAssertEqual(coalescer.receive(.changed(paths: ["d"])), [.changed(paths: ["c", "d"])])
        XCTAssertEqual(coalescer.receive(.rootChanged), [.rootChanged])
        XCTAssertEqual(coalescer.flushIfDue(), [])
    }
    func testCanonicalPathFilter() {
        let canonical = URL(fileURLWithPath: "/actual")
        let displayed = URL(fileURLWithPath: "/alias")
        XCTAssertEqual(MonitorPathFilter.displayedPath(for: "/actual/file", canonicalRoot: canonical, displayedRoot: displayed), "/alias/file")
        XCTAssertNil(MonitorPathFilter.displayedPath(for: "/actual/sub/file", canonicalRoot: canonical, displayedRoot: displayed))
        XCTAssertNil(MonitorPathFilter.displayedPath(for: "/actualOther/file", canonicalRoot: canonical, displayedRoot: displayed))
        XCTAssertEqual(MonitorPathFilter.displayedPath(for: "/actual", canonicalRoot: canonical, displayedRoot: displayed), "/alias")
    }
    func testPollingCreateRenameDeleteOnDisk() async throws {
        let temp = try TempDirectory()
        defer { try? temp.remove() }
        let fs = LiveFileSystem()
        let monitor = PollingMonitor(directory: temp.url, fileSystem: fs, interval: 60)
        try await monitor.start()
        var iterator = monitor.events.makeAsyncIterator()
        let a = temp.url.appendingPathComponent("a"), b = temp.url.appendingPathComponent("b")
        try await fs.createFileExclusively(at: a, contents: Data())
        await monitor.poll()
        let created = await iterator.next()
        XCTAssertEqual(created, .changed(paths: [a.path]))
        try await fs.moveItem(at: a, to: b)
        await monitor.poll()
        let renamed = await iterator.next()
        XCTAssertEqual(renamed, .changed(paths: [a.path, b.path]))
        try await fs.removeItem(at: b)
        await monitor.poll()
        let deleted = await iterator.next()
        XCTAssertEqual(deleted, .changed(paths: [b.path]))
        await monitor.stop()
        let end = await iterator.next()
        XCTAssertNil(end)
    }
    func testCacheLRUHiddenTTLAndInvalidation() async {
        let clock = FakeClock()
        let cache = ListingCache(capacity: 2, ttl: 3, clock: clock)
        let a = Location.directory(URL(fileURLWithPath: "/a")), b = Location.directory(URL(fileURLWithPath: "/b"))
        let entry = FileEntry(url: URL(fileURLWithPath: "/a/file"))
        let token = entry.changeToken
        await cache.store([entry], for: a, showHidden: false, token: token)
        let hidden = await cache.entries(for: a, showHidden: true, token: token)
        XCTAssertNil(hidden)
        await cache.store([entry], for: b, showHidden: false, token: token)
        _ = await cache.entries(for: a, showHidden: false, token: token)
        await cache.store([entry], for: a, showHidden: true, token: token)
        let evicted = await cache.entries(for: b, showHidden: false, token: token)
        XCTAssertNil(evicted)
        await cache.invalidate(a)
        let empty = await cache.entryCount
        XCTAssertEqual(empty, 0)
        await cache.store([entry], for: a, showHidden: false, token: token)
        clock.advance(by: 4)
        let expired = await cache.entries(for: a, showHidden: false, token: token)
        XCTAssertNil(expired)
        await cache.setEnabled(false)
        await cache.store([entry], for: a, showHidden: false, token: token)
        let disabled = await cache.entryCount
        XCTAssertEqual(disabled, 0)
    }
}

extension MonitorAndCacheTests {
    func testPollingReportsPermissionAndRootLoss() async throws {
        let fs = InMemoryFileSystem()
        let root = URL(fileURLWithPath: "/watched")
        try await fs.createDirectory(at: root)
        let monitor = PollingMonitor(directory: root, fileSystem: fs, interval: 60)
        try await monitor.start()
        var events = monitor.events.makeAsyncIterator()
        await fs.setFailure(.permissionDenied, at: root)
        await monitor.poll()
        let denied = await events.next()
        XCTAssertEqual(denied, .unavailable(.permissionDenied))
        await fs.setFailure(nil, at: root)
        try await fs.removeItem(at: root)
        await monitor.poll()
        let missing = await events.next()
        XCTAssertEqual(missing, .rootChanged)
        await monitor.stop()
    }
    func testFallbackStartsAndStopsOnLinux() async throws {
        let fs = InMemoryFileSystem()
        let monitor = FallbackMonitor(directory: URL(fileURLWithPath: "/"), fileSystem: fs)
        try await monitor.start()
        #if os(Linux)
        let name = await monitor.mechanism
        XCTAssertEqual(name, "polling")
        #endif
        await monitor.stop()
        var events = monitor.events.makeAsyncIterator()
        let end = await events.next()
        XCTAssertNil(end)
    }
    func testCacheRejectsChangedTokenAndOversizedListing() async {
        let cache = ListingCache(capacity: 1)
        let location = Location.recent
        let value = FileEntry(url: URL(fileURLWithPath: "/a"))
        await cache.store([value], for: location, showHidden: false, token: value.changeToken)
        let changed = ChangeToken(modificationDate: Date(), size: 1)
        let stale = await cache.entries(for: location, showHidden: false, token: changed)
        XCTAssertNil(stale)
        await cache.store([value, value], for: location, showHidden: false, token: value.changeToken)
        let count = await cache.entryCount
        XCTAssertEqual(count, 0)
    }
}
