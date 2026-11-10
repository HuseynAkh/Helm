// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import HelmCore
import HelmSearch
import HelmFileSystem

final class F3SearchTests: XCTestCase {
    func testTypedAndTextExtensionsMatch() throws {
        let entry = FileEntry(url: URL(fileURLWithPath: "/report.txt"), kind: .regular)
        for value in ["txt", ".txt", ".TXT", "TXT"] {
            let typed = try SearchQueryParser.compile(SearchRequest(text: "", scope: .home, filters: [.ext(value)]))
            let text = try SearchQueryParser.compile(SearchRequest(text: "ext:\(value)", scope: .home))
            XCTAssertTrue(typed.matches(entry), value); XCTAssertTrue(text.matches(entry), value)
            XCTAssertEqual(typed.clauses, text.clauses)
        }
        XCTAssertThrowsError(try SearchQueryParser.compile(SearchRequest(text: "", scope: .home, filters: [.ext("...")])))
    }
    func testOversizedEncodingsAreRejected() throws {
        let request = SearchRequest(text: "", scope: .home, filters: Array(repeating: .name(String(repeating: "a", count: 4096)), count: 256))
        XCTAssertThrowsError(try SavedSearchCodec.encode(SavedSearchDocument(name: "large", request: request)))
        for literal in ["a", "\"", "\\"] {
            XCTAssertThrowsError(try SavedSearchCodec.encode(SavedSearchDocument(name: String(repeating: literal, count: 1_048_576), request: SearchRequest(text: "", scope: .home))))
        }
        XCTAssertThrowsError(try FinderSavedSearchDocument(rawQuery: String(repeating: "a", count: 1_048_576), searchScopes: ["/tmp"]))
        let small = try FinderSavedSearchDocument(rawQuery: "x", searchScopes: ["/tmp"])
        XCTAssertThrowsError(try FinderSavedSearchCodec.replacing(small, rawQuery: String(repeating: "&", count: 1_048_576), searchScopes: ["/tmp"]))
    }
    func testDocumentByteBoundaryRoundTrips() throws {
        let request = SearchRequest(text: "", scope: .home)
        let overhead = try SavedSearchCodec.encode(SavedSearchDocument(name: "", request: request)).count
        let document = SavedSearchDocument(name: String(repeating: "a", count: 1_048_576 - overhead), request: request)
        let data = try SavedSearchCodec.encode(document)
        XCTAssertEqual(data.count, 1_048_576)
        XCTAssertEqual(try SavedSearchCodec.decode(data), document)
        var oversized = document; oversized.name.append("a")
        XCTAssertThrowsError(try SavedSearchCodec.encode(oversized))
        let finder = try FinderSavedSearchDocument(rawQuery: "", searchScopes: ["/tmp"])
        let finderOverhead = FinderSavedSearchCodec.encode(finder).count
        let boundary = try FinderSavedSearchDocument(rawQuery: String(repeating: "a", count: 1_048_576 - finderOverhead), searchScopes: ["/tmp"])
        let plist = FinderSavedSearchCodec.encode(boundary)
        XCTAssertEqual(plist.count, 1_048_576)
        XCTAssertEqual(try FinderSavedSearchCodec.decode(plist).rawQuery, boundary.rawQuery)
        XCTAssertThrowsError(try FinderSavedSearchDocument(rawQuery: boundary.rawQuery + "a", searchScopes: ["/tmp"]))
    }
    func testExplicitPackageAndSymlinkRootsAreNotEnumerated() async throws {
        let base = InMemoryFileSystem()
        let root = URL(fileURLWithPath: "/Tool.app")
        try await base.createDirectory(at: root)
        try await base.createFileExclusively(at: root.appendingPathComponent("secret"), contents: Data())
        let link = URL(fileURLWithPath: "/link")
        try await base.createSymbolicLink(at: link, destination: root)
        let fixture = SearchListingFixture(base: base, reversed: false, onEnumerate: { url in XCTFail("Unexpected enumeration: \(url.path)") })
        let context = SearchRankingContext(query: SearchQuery(text: "", scope: .home, bookmarkPaths: [], homeDirectory: root, lastDirectory: nil, showHidden: false, limit: 100))
        for url in [root, link] {
            let result = try await EnumerationSearchService(fileSystem: fixture).search(SearchSpecification(scope: .currentFolder(url), clauses: [], includeHidden: false), roots: [], context: context)
            XCTAssertTrue(result.results.isEmpty, url.path)
        }
    }
}
