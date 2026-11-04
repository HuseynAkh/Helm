// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmFileSystem
@testable import HelmSearch

final class SearchEngineTests: XCTestCase {
    let root = URL(fileURLWithPath: "/search")
    func context(limit: Int = 100) -> SearchRankingContext {
        SearchRankingContext(query: SearchQuery(text: "ignored", scope: .home, bookmarkPaths: [], homeDirectory: root,
            lastDirectory: nil, showHidden: false, limit: limit))
    }
    func engine(_ fs: any FileSystem) -> SearchEngine {
        SearchEngine(fileSystem: fs, resolver: SearchRootResolver(home: root, computerRoots: [root, root]))
    }
    func fixture() async throws -> InMemoryFileSystem {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        for directory in ["sub", ".hidden"] { try await fs.createDirectory(at: root.appendingPathComponent(directory)) }
        for path in ["report.txt", "report.pdf", "sub/report.txt", ".hidden/report.txt"] {
            try await fs.createFileExclusively(at: root.appendingPathComponent(path), contents: Data([1, 2]))
        }
        try await fs.createSymbolicLink(at: root.appendingPathComponent("loop"), destination: root)
        return fs
    }
    func testFiltersAndHiddenPolicy() async throws {
        let fs = try await fixture()
        let request = SearchRequest(text: "REPORT kind:REGULAR ext:txt size:>1 size:<3 after:1970-01-01 before:1971-01-01", scope: .home)
        let result = try await engine(fs).collect(request, context: context())
        XCTAssertEqual(Set(result.results.map(\.entry.url.path)), ["/search/report.txt", "/search/sub/report.txt"])
        XCTAssertFalse(result.truncated)
        var hidden = request; hidden.includeHidden = true
        let all = try await engine(fs).collect(hidden, context: context())
        XCTAssertEqual(all.results.count, 3)
    }
    func testStreamSnapshotsAndLimits() async throws {
        let fs = try await fixture()
        var snapshots: [SearchRankedBatch] = []
        for await batch in engine(fs).search(SearchRequest(text: "report"), context: context(limit: 2), batchSize: 1) { snapshots.append(batch) }
        XCTAssertEqual(snapshots.map { $0.results.count }, [1, 2])
        XCTAssertTrue(snapshots.allSatisfy(\.truncated))
        XCTAssertEqual(snapshots.last?.results.map(\.rank), [0, 1])
        let empty = try await engine(fs).collect(SearchRequest(text: "absent"), context: context())
        XCTAssertTrue(empty.results.isEmpty); XCTAssertFalse(empty.truncated)
        let zero = try await engine(fs).collect(SearchRequest(text: "report"), context: context(limit: 0))
        XCTAssertTrue(zero.results.isEmpty); XCTAssertTrue(zero.truncated)
    }
    func testBudgetsAndDuplicateRoots() async throws {
        let fs = try await fixture()
        let request = SearchRequest(text: "", scope: .thisMac)
        let bounded = try await engine(fs).collect(request, context: context(), options: SearchWalkOptions(visitLimit: 1))
        XCTAssertTrue(bounded.truncated); XCTAssertEqual(bounded.consideredCount, 1)
        let zero = try await engine(fs).collect(request, context: context(), options: SearchWalkOptions(visitLimit: -1))
        XCTAssertTrue(zero.truncated); XCTAssertTrue(zero.results.isEmpty)
        let shallow = try await engine(fs).collect(request, context: context(), options: SearchWalkOptions(maxDepth: 0))
        XCTAssertTrue(shallow.truncated)
        let full = try await engine(fs).collect(request, context: context())
        XCTAssertEqual(full.results.count, 5); XCTAssertFalse(full.truncated)
        let again = try await engine(fs).collect(request, context: context())
        XCTAssertEqual(full, again)
    }
    func testPermissionDiagnosticsAndOtherErrors() async throws {
        let fs = try await fixture()
        let denied = root.appendingPathComponent("sub")
        await fs.setFailure(.permissionDenied, at: denied)
        let warning = expectation(description: "permission diagnostic")
        let result = try await engine(fs).collect(SearchRequest(text: "report"), context: context()) { value in
            XCTAssertEqual(value, .unreadable(denied)); warning.fulfill()
        }
        await fulfillment(of: [warning], timeout: 1)
        XCTAssertTrue(result.truncated); XCTAssertEqual(result.results.count, 2)
        await fs.setFailure(.timedOut, at: root)
        do { _ = try await engine(fs).collect(SearchRequest(text: ""), context: context()); XCTFail("expected timeout") }
        catch { XCTAssertEqual(error as? FileSystemError, .timedOut) }
    }
    func testCancellationDuringEnumerationAndStreamFailure() async throws {
        let fs = try await fixture()
        await fs.setLatency(nanoseconds: 5_000_000_000)
        let service = engine(fs); let ctx = context()
        let task = Task { try await service.collect(SearchRequest(text: ""), context: ctx) }
        try await Task.sleep(nanoseconds: 20_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
        let failure = expectation(description: "unsupported criteria diagnostic")
        for await _ in service.search(SearchRequest(text: "tag:Work"), context: ctx, diagnostic: { value in
            if case .failed = value { failure.fulfill() }
        }) { XCTFail("failed queries must not emit success") }
        await fulfillment(of: [failure], timeout: 1)
        let cancelled = expectation(description: "stream worker stopped")
        let stream = service.search(SearchRequest(text: ""), context: ctx, diagnostic: { value in
            if value == .cancelled { cancelled.fulfill() }
        })
        let consumer = Task { for await _ in stream {} }
        try await Task.sleep(nanoseconds: 20_000_000)
        consumer.cancel(); await consumer.value
        await fulfillment(of: [cancelled], timeout: 1)
    }
    func testScopeResolverAndSymlinkRoot() async throws {
        let resolver = SearchRootResolver(home: root, computerRoots: [root])
        for scope: SearchScope in [.home, .userFolders, .computer, .thisMac, .currentFolder(root), .trash([root])] {
            let resolved = try await resolver.roots(for: scope); XCTAssertEqual(resolved, [root])
        }
        do { _ = try await resolver.roots(for: .recents); XCTFail("recents") }
        catch { XCTAssertEqual(error as? EnumerationSearchError, .recentsRequireMetadataSource) }
        let fs = try await fixture()
        let result = try await engine(fs).collect(SearchRequest(text: "", scope: .currentFolder(root.appendingPathComponent("loop"))), context: context())
        XCTAssertTrue(result.results.isEmpty)
    }
    func testCompositeMergeDisclosureAndTags() async throws {
        let fs = try await fixture()
        let record = SearchMetadataRecord(candidate: SearchCandidate(entry: FileEntry(url: root.appendingPathComponent("report.txt"))), tags: ["Work"])
        for availability: SearchIndexAvailability in [.available, .unavailable, .knownUnindexed] {
            let source = CompositeSearchSource(metadata: FakeMetadataSearchSource(snapshot: SearchMetadataSnapshot(records: [record], availability: availability)), enumeration: engine(fs))
            let result = try await source.search(SearchRequest(text: "report"), context: context())
            XCTAssertEqual(result.batch.results.count, availability == .available ? 1 : 3)
            XCTAssertEqual(result.disclosure.reason == nil, availability == .available)
        }
        let source = CompositeSearchSource(metadata: FakeMetadataSearchSource(snapshot: SearchMetadataSnapshot(records: [record])), enumeration: engine(fs))
        let tagged = try await source.search(SearchRequest(text: "tag:Work"), context: context(), userRequestedFallback: true)
        XCTAssertEqual(tagged.batch.results.count, 1)
        XCTAssertTrue(tagged.disclosure.unsupportedCriteria); XCTAssertTrue(tagged.batch.truncated)
        XCTAssertEqual(tagged.disclosure.reason, .userRequested)
        let emptySource = CompositeSearchSource(metadata: FakeMetadataSearchSource(snapshot: SearchMetadataSnapshot(records: [])), enumeration: engine(fs))
        let empty = try await emptySource.search(SearchRequest(text: "report"), context: context())
        XCTAssertTrue(empty.batch.results.isEmpty); XCTAssertNil(empty.disclosure.reason)
    }
    func testFakeMetadataCancellation() async throws {
        let source = FakeMetadataSearchSource(snapshot: SearchMetadataSnapshot(records: []), delayNanoseconds: 5_000_000_000)
        let task = Task { try await source.snapshot(for: SearchSpecification(scope: .home, clauses: [], includeHidden: false)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("expected cancellation") } catch is CancellationError {}
    }
    func testPackagePolicyAndDeliveryOrderIndependence() async throws {
        let fs = try await fixture()
        let package = root.appendingPathComponent("Tool.app")
        try await fs.createDirectory(at: package)
        try await fs.createFileExclusively(at: package.appendingPathComponent("report.txt"), contents: Data())
        let forward = engine(SearchListingFixture(base: fs, reversed: false))
        let backward = engine(SearchListingFixture(base: fs, reversed: true))
        let request = SearchRequest(text: "report")
        let closed = try await forward.collect(request, context: context())
        XCTAssertEqual(closed.results.count, 3)
        let opened = try await forward.collect(request, context: context(), options: SearchWalkOptions(includePackageContents: true))
        XCTAssertEqual(opened.results.count, 4)
        for limit in [1, 3, 100] {
            let options = SearchWalkOptions(visitLimit: limit)
            let a = try await forward.collect(request, context: context(), options: options)
            let b = try await backward.collect(request, context: context(), options: options)
            XCTAssertEqual(a, b)
        }
        let packageRoot = SearchRequest(text: "report", scope: .currentFolder(package))
        let skipped = try await forward.collect(packageRoot, context: context())
        XCTAssertTrue(skipped.results.isEmpty)
        let included = try await forward.collect(packageRoot, context: context(), options: SearchWalkOptions(includePackageContents: true))
        XCTAssertEqual(included.results.count, 1)
    }

    func testCompositeScopeBoundaryRecentsAndUpstreamTruncation() async throws {
        let fs = try await fixture()
        let records = ["/search/report", "/searching/report", "/outside/report"].map {
            SearchMetadataRecord(candidate: SearchCandidate(entry: FileEntry(url: URL(fileURLWithPath: $0))))
        }
        let source = CompositeSearchSource(metadata: FakeMetadataSearchSource(snapshot:
            SearchMetadataSnapshot(records: records, availability: .knownUnindexed, truncated: true)), enumeration: engine(fs))
        let scoped = try await source.search(SearchRequest(text: "report"), context: context())
        XCTAssertEqual(scoped.disclosure.reason, .knownUnindexed)
        XCTAssertTrue(scoped.batch.truncated)
        XCTAssertFalse(scoped.batch.results.contains { $0.entry.url.path.hasPrefix("/outside") || $0.entry.url.path.hasPrefix("/searching") })
        let recents = try await source.search(SearchRequest(text: "report", scope: .recents), context: context())
        XCTAssertEqual(recents.batch.results.count, 3)
        XCTAssertTrue(recents.disclosure.unsupportedCriteria)
        let unavailable = CompositeSearchSource(metadata: FakeMetadataSearchSource(snapshot:
            SearchMetadataSnapshot(records: [], availability: .unavailable)), enumeration: engine(fs))
        let fallback = try await unavailable.search(SearchRequest(text: "report"), context: context())
        XCTAssertEqual(fallback.disclosure.reason, .metadataUnavailable)
    }
    func testEmptyStreamAndInvalidBatchSize() async throws {
        let fs = try await fixture()
        var count = 0
        for await batch in engine(fs).search(SearchRequest(text: "absent"), context: context(), batchSize: -1) {
            count += 1; XCTAssertTrue(batch.results.isEmpty); XCTAssertFalse(batch.truncated)
        }
        XCTAssertEqual(count, 1)
    }

}
