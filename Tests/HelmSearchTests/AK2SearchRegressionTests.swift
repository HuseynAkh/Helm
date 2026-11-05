// DRAFT: pending Opus review. Regression coverage for OK1 AK2.
import Foundation
import XCTest
import HelmCore
import HelmFileSystem
@testable import HelmSearch

final class AK2SearchRegressionTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/search")
    private func context() -> SearchRankingContext {
        SearchRankingContext(query: SearchQuery(text: "", scope: .home, bookmarkPaths: [],
            homeDirectory: root, lastDirectory: nil, showHidden: false, limit: 100))
    }
    private func engine(_ fs: any FileSystem) -> SearchEngine {
        SearchEngine(fileSystem: fs, resolver: SearchRootResolver(home: root))
    }
    func testQuotedAndEscapedFilterSyntaxRemainsLiteral() throws {
        for text in ["\"kind:x\"", "kind\\:x", "ki\"nd\":x"] {
            let specification = try SearchQueryParser.compile(SearchRequest(text: text))
            XCTAssertEqual(specification.clauses, [.name("kind:x")])
            XCTAssertTrue(specification.matches(FileEntry(url: root.appendingPathComponent("kind:x"))))
        }
        XCTAssertEqual(try SearchQueryParser.compile(SearchRequest(text: "kind:folder")).clauses, [.kind(.directory)])
    }
    func testRejectsNonlocalScopeIncludingSavedDefinitions() throws {
        for spelling in ["https://example.com/search", "file://server/search", "file:///search?q=x", "file:///search#x", "file:///search/a%2Fb", "file:///search/%00"] {
            let url = try XCTUnwrap(URL(string: spelling))
            for scope: SearchScope in [.currentFolder(url), .trash([root, url])] {
                let request = SearchRequest(text: "report", scope: scope)
                XCTAssertThrowsError(try SearchQueryParser.compile(request), spelling)
                let data = try JSONEncoder().encode(SavedSearchDocument(name: "bad", request: request))
                XCTAssertThrowsError(try SavedSearchCodec.decode(data), spelling)
            }
        }
    }
    func testSavedDefinitionAdmissionUsesStrictLocalURL() throws {
        let data = try SavedSearchCodec.encode(SavedSearchDocument(name: "valid", request: SearchRequest(text: "report")))
        for spelling in ["file:///search?q=x", "file:///search#x", "file://user@localhost/search", "file:///search/a%2Fb", "file:///search/%00"] {
            let plan = SavedSearchOpenPlan(definitionURL: try XCTUnwrap(URL(string: spelling)), data: data)
            guard case .rejected = plan.content else { XCTFail(spelling); continue }
            XCTAssertNil(plan.definitionRemovalIntent)
        }
        let plan = SavedSearchOpenPlan(definitionURL: try XCTUnwrap(URL(string: "file://LOCALHOST/search")), data: data)
        XCTAssertNotNil(plan.searchRequest)
        XCTAssertNotNil(plan.definitionRemovalIntent)
    }
    func testSkippedExplicitRootsAreDisclosed() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        let link = root.appendingPathComponent("link")
        try await fs.createSymbolicLink(at: link, destination: root)
        let warning = expectation(description: "root not searchable")
        let result = try await engine(fs).collect(SearchRequest(text: "", scope: .currentFolder(link)), context: context()) {
            XCTAssertEqual($0, .rootNotSearchable(link)); warning.fulfill()
        }
        XCTAssertTrue(result.truncated)
        XCTAssertTrue(result.results.isEmpty)
        await fulfillment(of: [warning], timeout: 1)
    }
    func testVanishedSubdirectoryRetainsOtherResults() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        let missing = root.appendingPathComponent("vanished")
        try await fs.createDirectory(at: missing)
        try await fs.createFileExclusively(at: root.appendingPathComponent("report"), contents: Data())
        await fs.setFailure(.notFound, at: missing)
        let warning = expectation(description: "missing child")
        let result = try await engine(fs).collect(SearchRequest(text: "report"), context: context()) {
            XCTAssertEqual($0, .unreadable(missing)); warning.fulfill()
        }
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.results.map(\.entry.name), ["report"])
        await fulfillment(of: [warning], timeout: 1)
    }
    func testMissingRootAmongSeveralIsPartialButSingleRootFails() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        try await fs.createFileExclusively(at: root.appendingPathComponent("report"), contents: Data())
        let missing = URL(fileURLWithPath: "/missing")
        let result = try await engine(fs).collect(SearchRequest(text: "report", scope: .trash([missing, root])), context: context())
        XCTAssertTrue(result.truncated)
        XCTAssertEqual(result.results.count, 1)
        do {
            _ = try await engine(fs).collect(SearchRequest(text: "report", scope: .currentFolder(missing)), context: context())
            XCTFail("Single missing root must fail")
        } catch { XCTAssertEqual(error as? FileSystemError, .notFound) }
    }
    func testVisitBudgetReachesSiblingsBeforeGrandchildren() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        for path in ["a", "b", "b/deep"] { try await fs.createDirectory(at: root.appendingPathComponent(path)) }
        for path in ["a/report", "b/deep/report"] { try await fs.createFileExclusively(at: root.appendingPathComponent(path), contents: Data()) }
        let result = try await engine(fs).collect(SearchRequest(text: "report"), context: context(), options: SearchWalkOptions(visitLimit: 4))
        XCTAssertEqual(result.results.map(\.entry.url.path), ["/search/a/report"])
        XCTAssertTrue(result.truncated)
    }
}

extension AK2SearchRegressionTests {
    func testDefaultScopesIncludeInjectedBookmarksAndRemovableVolumes() async throws {
        let bookmark = URL(fileURLWithPath: "/Volumes/Work/Project")
        let volume = URL(fileURLWithPath: "/Volumes/USB")
        let resolver = SearchRootResolver(home: root, bookmarkRoots: [bookmark, root], removableVolumeRoots: [volume, bookmark])
        for scope: SearchScope in [.home, .userFolders] {
            let roots = try await resolver.roots(for: scope)
            XCTAssertEqual(roots, [root, bookmark, volume])
        }
        let fs = InMemoryFileSystem()
        let record = SearchMetadataRecord(candidate: SearchCandidate(entry: FileEntry(url: bookmark.appendingPathComponent("report"))))
        let source = CompositeSearchSource(metadata: FakeMetadataSearchSource(snapshot: SearchMetadataSnapshot(records: [record])),
            enumeration: SearchEngine(fileSystem: fs, resolver: resolver))
        let result = try await source.search(SearchRequest(text: "report"), context: context())
        XCTAssertEqual(result.batch.results.map(\.entry.url), [record.candidate.entry.url])
        let narrow = try await resolver.roots(for: .currentFolder(root))
        XCTAssertEqual(narrow, [root])
    }
    func testPreferredRootsDiscoverVisibleHomeDirectoriesOnce() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        for name in ["Clients", "Library", ".hidden", "Documents"] { try await fs.createDirectory(at: root.appendingPathComponent(name)) }
        try await fs.createFileExclusively(at: root.appendingPathComponent("plain"), contents: Data())
        let roots = try await PreferredRoots.discover(home: root, fileSystem: fs)
        XCTAssertTrue(roots.contains(root.appendingPathComponent("Clients")))
        XCTAssertFalse(roots.contains(root.appendingPathComponent("Library")))
        XCTAssertFalse(roots.contains(root.appendingPathComponent(".hidden")))
        XCTAssertFalse(roots.contains(root.appendingPathComponent("plain")))
        XCTAssertEqual(roots.filter { $0.lastPathComponent == "Documents" }.count, 1)
        let candidate = SearchCandidate(entry: FileEntry(url: root.appendingPathComponent("Clients/report")))
        let baseline = context()
        let discovered = SearchRankingContext(query: baseline.query, preferredRoots: roots)
        XCTAssertGreaterThan(SearchRanker.score(candidate, context: discovered, now: Date()), SearchRanker.score(candidate, context: baseline, now: Date()))
    }
}

extension AK2SearchRegressionTests {
    func testNonChildListingIsDisclosedWithoutLeakingResults() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        let outside = FileEntry(url: URL(fileURLWithPath: "/private/search/report"))
        let warning = expectation(description: "nonchild disclosure")
        let result = try await engine(AK2ListingFixture(base: fs, additionalEntries: [outside])).collect(
            SearchRequest(text: "report"), context: context()) {
                XCTAssertEqual($0, .droppedEntry(outside.url)); warning.fulfill()
            }
        await fulfillment(of: [warning], timeout: 1)
        XCTAssertTrue(result.truncated); XCTAssertTrue(result.results.isEmpty)
    }
    func testDirectoryVanishingAtEnumerationKeepsEarlierResults() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        let sub = root.appendingPathComponent("sub")
        try await fs.createDirectory(at: sub)
        try await fs.createFileExclusively(at: root.appendingPathComponent("report"), contents: Data())
        let result = try await engine(AK2ListingFixture(base: fs, vanishedListings: [sub])).collect(
            SearchRequest(text: "report"), context: context())
        XCTAssertTrue(result.truncated); XCTAssertEqual(result.results.map(\.entry.name), ["report"])
    }
    func testLegacyFallbackAlsoDisclosesSkippedAndVanishedRoots() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        let link = root.appendingPathComponent("link")
        try await fs.createSymbolicLink(at: link, destination: root)
        let service = EnumerationSearchService(fileSystem: fs)
        let skipped = try await service.search(SearchSpecification(scope: .currentFolder(link), clauses: [], includeHidden: false), roots: [], context: context())
        XCTAssertTrue(skipped.truncated)
        let partial = try await service.search(SearchSpecification(scope: .trash([root, URL(fileURLWithPath: "/missing")]), clauses: [], includeHidden: false), roots: [], context: context())
        XCTAssertTrue(partial.truncated)
    }
}

extension AK2SearchRegressionTests {
    func testLiteralStateDoesNotLeakToFollowingFilter() throws {
        let value = try SearchQueryParser.compile(SearchRequest(text: "\"kind:x\" kind:folder"))
        XCTAssertEqual(value.clauses, [.name("kind:x"), .kind(.directory)])
        let escaped = try SearchQueryParser.compile(SearchRequest(text: "tag:\"Work Stuff\""))
        XCTAssertEqual(escaped.clauses, [.name("tag:Work Stuff")])
    }
    func testValidLocalScopeSpellingsRemainAccepted() throws {
        for spelling in ["file://LOCALHOST/search", "file:///search/", "file:///search/caf%C3%A9", "file:///search/a%252Fb"] {
            let url = try XCTUnwrap(URL(string: spelling))
            XCTAssertNoThrow(try SearchQueryParser.compile(SearchRequest(text: "report", scope: .currentFolder(url))))
        }
    }
    func testInjectedNonlocalRootsAreRejectedBeforeEnumeration() async throws {
        let remote = try XCTUnwrap(URL(string: "https://example.com/search"))
        let service = SearchEngine(fileSystem: InMemoryFileSystem(), resolver: SearchRootResolver(home: remote))
        do {
            _ = try await service.collect(SearchRequest(text: "report"), context: context())
            XCTFail("Nonlocal resolver root must be rejected")
        } catch { XCTAssertEqual(error as? SearchParseError, .nonLocalRoot(remote)) }
    }
    func testPreferredRootsPropagateReadFailuresAndCancellation() async throws {
        let fs = InMemoryFileSystem()
        try await fs.createDirectory(at: root)
        await fs.setFailure(.permissionDenied, at: root)
        do {
            _ = try await PreferredRoots.discover(home: root, fileSystem: fs)
            XCTFail("Unreadable home must be disclosed by the host")
        } catch { XCTAssertEqual(error as? FileSystemError, .permissionDenied) }
        let entered = expectation(description: "root discovery entered enumeration")
        let fixture = SearchListingFixture(base: fs, reversed: false, onEnumerate: { _ in entered.fulfill() }, suspendEnumeration: true)
        let home = root
        let task = Task { try await PreferredRoots.discover(home: home, fileSystem: fixture) }
        await fulfillment(of: [entered], timeout: 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch is CancellationError {}
    }
}
