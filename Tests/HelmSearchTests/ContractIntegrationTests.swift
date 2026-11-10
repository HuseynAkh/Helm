// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import HelmCore
import HelmSearch
import HelmFileSystem

final class ContractIntegrationTests: XCTestCase {
    func testSharedQueryRetainsFiltersAndSymbolicScope() throws {
        let query = SearchQuery(text: "report", scope: .recents, bookmarkPaths: [],
                                homeDirectory: URL(fileURLWithPath: "/home"), lastDirectory: nil,
                                showHidden: true, limit: 10, filters: [.kind(.regular), .after(.distantPast)])
        let specification = try SearchQueryParser.compile(SearchRequest(query: query))
        XCTAssertEqual(specification.scope, .recents)
        XCTAssertTrue(specification.includeHidden)
        XCTAssertEqual(specification.clauses, query.filters + [.name("report")])
        XCTAssertTrue(specification.matches(FileEntry(url: URL(fileURLWithPath: "/report"))))
        XCTAssertFalse(specification.matches(FileEntry(url: URL(fileURLWithPath: "/report"), kind: .directory)))
    }

    func testLegacyAndSymbolicScopesUseOnlyTheirDeclaredRoots() async throws {
        let fs = InMemoryFileSystem()
        let home = URL(fileURLWithPath: "/home")
        let other = URL(fileURLWithPath: "/other")
        for root in [home, other] {
            try await fs.createDirectory(at: root)
            try await fs.createFileExclusively(at: root.appendingPathComponent("report"), contents: Data())
        }
        for (scope, expected) in [(SearchScope.home, home), (.userFolders, home),
                                  (.thisMac, other), (.computer, other), (.trash([home]), home)] {
            let query = SearchQuery(text: "report", scope: scope, bookmarkPaths: [], homeDirectory: home,
                                    lastDirectory: nil, showHidden: false, limit: 10)
            let specification = try SearchQueryParser.compile(SearchRequest(query: query))
            let result = try await EnumerationSearchService(fileSystem: fs).search(specification, roots: [other],
                context: SearchRankingContext(query: query))
            XCTAssertEqual(result.results.map { $0.entry.url }, [expected.appendingPathComponent("report")])
        }
    }

    func testSharedEventRetainsTruncation() {
        let batch = SearchRankedBatch(results: [], truncated: true, candidateLimitReached: true, consideredCount: 450)
        let event = SearchEvent.results(batch, isFinal: true)
        guard case .results(let received, let final) = event else { return XCTFail("Missing results") }
        XCTAssertEqual(received, batch)
        XCTAssertTrue(final)
        XCTAssertTrue(received.truncated)
    }
}
