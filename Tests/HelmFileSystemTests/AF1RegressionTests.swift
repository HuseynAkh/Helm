// DRAFT: pending review, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmTestKit
@testable import HelmFileSystem
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class AF1RegressionTests: XCTestCase {
    func testNativeErrorMapping() {
        let cases: [(String, Int, FileSystemError)] = [
            (NSCocoaErrorDomain, 3328, .unsupported),
            (NSCocoaErrorDomain, 642, .permissionDenied),
            (NSCocoaErrorDomain, 640, .other("No space")),
            (NSPOSIXErrorDomain, Int(ENOTSUP), .unsupported),
            (NSPOSIXErrorDomain, Int(EXDEV), .unsupported),
            (NSPOSIXErrorDomain, Int(EROFS), .permissionDenied),
            (NSPOSIXErrorDomain, Int(ENOSPC), .other("No space"))
        ]
        for (domain, code, expected) in cases {
            let error = NSError(domain: domain, code: code)
            XCTAssertEqual(FileSystemError.mapping(error), expected, "\(domain):\(code)")
            XCTAssertEqual(FileSystemError.mapping(NSError(domain: "wrapper", code: 1,
                userInfo: [NSUnderlyingErrorKey: error])), expected)
        }
        XCTAssertEqual(FileSystemError.mapping(FileSystemError.timedOut), .timedOut)
        XCTAssertEqual(FileSystemError.mapping(NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST))),
                       .collision(noMutation: false))
    }

    func testEntryUsesMetadataSeamOnceAndSharesListingVolume() async throws {
        let temp = try TempDirectory()
        let file = temp.url.appendingPathComponent("entry")
        try Data().write(to: file)
        let probe = AF1MetadataProbe()
        let fs = LiveFileSystem { url, resolve, volume in
            probe.record(resolve: resolve)
            return FileEntry(url: url, size: 123, volumeIdentifier: volume)
        }
        var listed: [FileEntry] = []
        for try await batch in fs.enumerate(temp.url) { listed += batch }
        XCTAssertEqual(probe.count, 1)
        let single = try await fs.entry(at: file)
        XCTAssertEqual(probe.count, 2)
        XCTAssertEqual(single.size, 123)
        XCTAssertEqual(single.volumeIdentifier, try XCTUnwrap(listed.first).volumeIdentifier)
        XCTAssertNotNil(single.volumeIdentifier)
        XCTAssertTrue(probe.allResolved)
        let native = try await LiveFileSystem().entry(at: file)
        XCTAssertEqual(native.volumeIdentifier, single.volumeIdentifier)
    }

    func testPackageRootLoadsAndCachesContents() async throws {
        let temp = try TempDirectory()
        let file = temp.url.appendingPathComponent("Contents")
        try Data().write(to: file)
        let fs = LiveFileSystem { url, _, volume in
            FileEntry(url: url, kind: url == temp.url ? .package : .regular, volumeIdentifier: volume)
        }
        let loader = DirectoryLoader(fileSystem: fs)
        // Package presentation remains non-directory-like; explicit navigation is permitted.
        XCTAssertFalse(FileEntry(url: temp.url, kind: .package).isDirectoryLike)
        for _ in 0..<2 {
            let entries = try await loader.snapshot(.directory(temp.url))
            XCTAssertEqual(entries.map(\.name), ["Contents"])
        }
    }

    func testPollingFailureTransitionsAndRecovery() async throws {
        let fs = InMemoryFileSystem()
        let root = URL(fileURLWithPath: "/watched")
        try await fs.createDirectory(at: root)
        let monitor = PollingMonitor(directory: root, fileSystem: fs, interval: 60)
        try await monitor.start()
        await fs.setFailure(.permissionDenied, at: root)
        await monitor.poll(); await monitor.poll()
        await fs.setFailure(.timedOut, at: root)
        await monitor.poll(); await monitor.poll()
        await fs.setFailure(nil, at: root)
        await monitor.poll(); await monitor.poll()
        await fs.setFailure(.notFound, at: root)
        await monitor.poll(); await monitor.poll()
        await fs.setFailure(nil, at: root)
        await monitor.poll()
        await monitor.stop()
        var events: [MonitorEvent] = []
        for await event in monitor.events { events.append(event) }
        XCTAssertEqual(events, [.unavailable(.permissionDenied), .unavailable(.unavailable),
                                .rescan, .rootChanged, .rescan])
    }

    func testFailedMonitorRetiresAndNextSubscriberRetries() async throws {
        let factory = AF1MonitorFactory()
        let registry = MonitorRegistry { _ in factory.make() }
        let root = URL(fileURLWithPath: "/watched")
        let stream = await registry.subscribe(path: root)
        let ended = expectation(description: "Failed subscription finishes")
        let consumer = Task {
            var events: [MonitorEvent] = []
            for await event in stream { events.append(event) }
            ended.fulfill()
            return events
        }
        await fulfillment(of: [ended], timeout: 2)
        let retiredCount = await registry.observedDirectoryCount
        XCTAssertEqual(retiredCount, 0)
        consumer.cancel()
        let failures = await consumer.value
        XCTAssertEqual(failures, [.unavailable(.unavailable)])
        let retry = await registry.subscribe(path: root)
        XCTAssertEqual(factory.count, 2)
        let received = expectation(description: "Retry receives events")
        let retriedConsumer = Task {
            for await event in retry { if event == .rescan { received.fulfill() } }
        }
        try await factory.healthy.start()
        await factory.healthy.emit(.rescan)
        await fulfillment(of: [received], timeout: 2)
        await registry.stopAll()
        await retriedConsumer.value
    }

    func testFakeUsesPlannerUnicodeCollisionOracle() async throws {
        for sensitive in [false, true] {
            for (first, second) in [("Straße", "STRASSE"), ("Σ", "ς"), ("é", "e\u{301}"), ("I", "ı"), ("ǅ", "ǆ")] {
                let fs = InMemoryFileSystem(caseSensitive: sensitive)
                let a = URL(fileURLWithPath: "/" + first)
                let b = URL(fileURLWithPath: "/" + second)
                try await fs.createFileExclusively(at: a, contents: Data())
                let collision = FileNameComparison.key(first, caseSensitive: sensitive)
                    == FileNameComparison.key(second, caseSensitive: sensitive)
                do {
                    try await fs.createFileExclusively(at: b, contents: Data())
                    XCTAssertFalse(collision, "\(first)/\(second)")
                } catch {
                    XCTAssertTrue(collision, "\(first)/\(second)")
                    XCTAssertEqual(error as? FileSystemError, .collision(noMutation: true))
                }
            }
        }
    }
}

private final class AF1MetadataProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var resolves: [Bool] = []
    func record(resolve: Bool) { lock.lock(); defer { lock.unlock() }; resolves.append(resolve) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return resolves.count }
    var allResolved: Bool { lock.lock(); defer { lock.unlock() }; return resolves.allSatisfy { $0 } }
}
private struct AF1FailingMonitor: DirectoryMonitor {
    let events = AsyncStream<MonitorEvent> { $0.finish() }
    func start() async throws { throw FileSystemError.permissionDenied }
    func stop() async {}
}
private final class AF1MonitorFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let healthy = InMemoryMonitor()
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
    func make() -> any DirectoryMonitor {
        lock.lock(); defer { lock.unlock() }; calls += 1
        return calls == 1 ? AF1FailingMonitor() : healthy
    }
}

extension AF1RegressionTests {
    func testPrivateCanonicalRootMapsMissingChildToDisplayedPath() {
        let name = "helm-af1-missing-" + UUID().uuidString
        let actual = MonitorPathFilter.displayedPath(for: "/private/tmp/" + name,
            canonicalRoot: URL(fileURLWithPath: "/private/tmp"),
            displayedRoot: URL(fileURLWithPath: "/tmp"))
        XCTAssertEqual(actual, "/tmp/" + name)
    }
    func testMonitorFilterIsLexicalForRootDescendantsAndSiblings() {
        let canonical = URL(fileURLWithPath: "/private/tmp/w"), displayed = URL(fileURLWithPath: "/tmp/w")
        func map(_ path: String) -> String? {
            MonitorPathFilter.displayedPath(for: path, canonicalRoot: canonical, displayedRoot: displayed)
        }
        XCTAssertEqual(map("/private/tmp/w"), "/tmp/w")
        XCTAssertEqual(map("/private/tmp/w/gone"), "/tmp/w/gone")
        XCTAssertEqual(map("/private/tmp/w/./gone"), "/tmp/w/gone")
        XCTAssertNil(map("/private/tmp/w/sub/gone"), "Only direct children are reported")
        XCTAssertNil(map("/private/tmp/wider/gone"), "A sibling sharing a string prefix is not a child")
        XCTAssertNil(map("/tmp/w/gone"), "Only the registered spelling matches")
        XCTAssertEqual(MonitorPathFilter.displayedPath(for: "/gone", canonicalRoot: URL(fileURLWithPath: "/"),
            displayedRoot: URL(fileURLWithPath: "/")), "/gone")
    }

    func testLiveConditionalMutationRefusesWithoutChangingDisk() async throws {
        let temp = try TempDirectory()
        let source = temp.url.appendingPathComponent("source")
        let destination = temp.url.appendingPathComponent("destination")
        let payload = Data("preserve".utf8)
        try payload.write(to: source)
        let fs = LiveFileSystem()
        let evidence = try await fs.mutationPrecondition(at: source)
        do {
            _ = try await fs.mutate(.copy(to: destination), source: source, requiring: evidence)
            XCTFail("Live conditional mutation must remain refused pending owner decision")
        } catch { XCTAssertEqual(error as? ConditionalMutationError, .unsupported) }
        XCTAssertEqual(try Data(contentsOf: source), payload)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }
}
