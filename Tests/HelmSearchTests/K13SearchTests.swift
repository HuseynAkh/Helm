// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmSearch

final class K13SearchTests: XCTestCase {
    private var context: SearchRankingContext {
        SearchRankingContext(query: SearchQuery(text: "report", scope: .userFolders, bookmarkPaths: [], homeDirectory: URL(fileURLWithPath: "/home"), lastDirectory: nil, showHidden: false, limit: 150))
    }
    /// F-044: parser accepts 4096 bytes and rejects 4097.
    func testExactUTF8Budget() throws {
        XCTAssertEqual(try SearchQueryParser.tokenize(String(repeating: "x", count: 4096)).count, 1)
        XCTAssertThrowsError(try SearchQueryParser.tokenize(String(repeating: "x", count: 4097)))
    }
    /// F-044: byte budget is independent of grapheme count.
    func testEmojiUTF8Budget() throws {
        XCTAssertEqual(try SearchQueryParser.tokenize(String(repeating: "😀", count: 1024)).count, 1)
        XCTAssertThrowsError(try SearchQueryParser.tokenize(String(repeating: "😀", count: 1025)))
    }
    /// F-044: exactly 128 tokens accepted.
    func testTokenBoundary() throws {
        XCTAssertEqual(try SearchQueryParser.tokenize(Array(repeating: "x", count: 128).joined(separator: " ")).count, 128)
        XCTAssertThrowsError(try SearchQueryParser.tokenize(Array(repeating: "x", count: 129).joined(separator: " ")))
    }
    /// F-044: programmatic filters share the clause limit.
    func testCombinedFilterBoundary() throws {
        let filters = Array(repeating: SearchClause.name("x"), count: 255)
        XCTAssertEqual(try SearchQueryParser.compile(SearchRequest(text: "x", filters: filters)).clauses.count, 256)
        XCTAssertThrowsError(try SearchQueryParser.compile(SearchRequest(text: "x y", filters: filters)))
    }
    /// F-044: Unicode whitespace separates tokens.
    func testUnicodeWhitespace() throws {
        XCTAssertEqual(try SearchQueryParser.tokenize("a\u{2003}b\u{00A0}c"), ["a", "b", "c"])
    }
    /// F-044: predicate syntax is data.
    func testQuotedInjectionStaysLiteral() throws {
        let spec = try SearchQueryParser.compile(SearchRequest(text: #""x OR TRUEPREDICATE""#))
        XCTAssertEqual(spec.clauses, [.name("x OR TRUEPREDICATE")])
        XCTAssertFalse(spec.matches(FileEntry(url: URL(fileURLWithPath: "/unrelated"))))
    }
    /// F-044: unknown filters do not broaden search.
    func testUnknownColonKeyLiteral() throws {
        XCTAssertEqual(try SearchQueryParser.compile(SearchRequest(text: "https://example.invalid")).clauses, [.name("https://example.invalid")])
    }
    /// F-044: dates are strict Gregorian calendar values.
    func testLeapDayValidation() throws {
        XCTAssertNoThrow(try SearchQueryParser.compile(SearchRequest(text: "before:2024-02-29")))
        for text in ["before:2023-02-29", "after:2024-2-29", "after:2024-13-01"] { XCTAssertThrowsError(try SearchQueryParser.compile(SearchRequest(text: text))) }
    }
    /// F-044: Int64 boundaries parse without overflow.
    func testMaximumSizeFilter() throws {
        XCTAssertEqual(try SearchQueryParser.compile(SearchRequest(text: "size:>9223372036854775807")).clauses, [.sizeGreaterThan(Int64.max)])
        XCTAssertThrowsError(try SearchQueryParser.compile(SearchRequest(text: "size:>9223372036854775808")))
    }
    /// F-044: NFC/NFD and diacritics are searchable.
    func testCanonicalNameMatching() throws {
        let spec = try SearchQueryParser.compile(SearchRequest(text: "CAFÉ"))
        XCTAssertTrue(spec.matches(FileEntry(url: URL(fileURLWithPath: "/cafe\u{301}.txt"))))
        XCTAssertTrue(spec.matches(FileEntry(url: URL(fileURLWithPath: "/cafe.txt"))))
    }
    /// F-044: repeated filters are conjunctive.
    func testContradictoryFiltersReturnNothing() throws {
        let spec = try SearchQueryParser.compile(SearchRequest(text: "ext:pdf ext:txt"))
        XCTAssertFalse(spec.matches(FileEntry(url: URL(fileURLWithPath: "/report.pdf"))))
    }
    /// F-046, B-099: fallback requires a positive reason.
    func testFallbackTruthTable() throws {
        for available in [false, true] { for unindexed in [false, true] { for requested in [false, true] {
            XCTAssertEqual(SearchFallbackPolicy.shouldEnumerate(spotlightAvailable: available, knownUnindexed: unindexed, userRequested: requested), !available || unindexed || requested)
        } } }
    }
    /// F-045, B-022: equal scores have natural deterministic order.
    func testNaturalOrderIsInputIndependent() throws {
        let candidates = ["10", "2", "1"].map { SearchCandidate(entry: FileEntry(url: URL(fileURLWithPath: "/r/report" + $0))) }
        let ranked = SearchRanker.rank(candidates, context: context)
        XCTAssertEqual(ranked.results.map(\.entry.name), ["report1", "report2", "report10"])
        XCTAssertEqual(SearchRanker.rank(candidates.reversed(), context: context).results, ranked.results)
    }
    /// B-026: exact cap is not mislabeled as upstream truncation.
    func testCapExactlyReached() throws {
        let candidates = (0..<450).map { SearchCandidate(entry: FileEntry(url: URL(fileURLWithPath: "/r/\($0)"))) }
        let batch = SearchRanker.rank(candidates, context: context)
        XCTAssertFalse(batch.candidateLimitReached)
        XCTAssertEqual(batch.consideredCount, 450)
        XCTAssertTrue(batch.truncated)
    }
    /// B-026: empty partial results retain the truncation signal.
    func testEmptyUpstreamTruncation() throws {
        let batch = SearchRanker.rank([], context: context, upstreamTruncated: true)
        XCTAssertTrue(batch.truncated)
        XCTAssertTrue(batch.candidateLimitReached)
        XCTAssertEqual(batch.consideredCount, 0)
    }
    /// F-043: saved query encoding is reproducible.
    func testSavedSearchDeterministicBytes() throws {
        let document = SavedSearchDocument(name: "مرحبا😀", request: SearchRequest(text: "cafe\u{301}"))
        let bytes = try SavedSearchCodec.encode(document)
        XCTAssertEqual(try SavedSearchCodec.encode(document), bytes)
        XCTAssertEqual(try SavedSearchCodec.decode(bytes), document)
    }
    /// F-043: oversized files fail before decoding.
    func testSavedSearchOversize() throws {
        XCTAssertThrowsError(try SavedSearchCodec.decode(Data(repeating: 32, count: 1_048_577)))
    }
    /// F-043: future files are not interpreted as current.
    func testSavedSearchFutureVersion() throws {
        let data = try JSONEncoder().encode(SavedSearchDocument(name: "future", request: SearchRequest(text: "x"), version: 99))
        XCTAssertThrowsError(try SavedSearchCodec.decode(data)) { XCTAssertEqual($0 as? SavedSearchError, .unsupportedVersion(99)) }
    }
    /// F-043: unknown plist data survives exact re-export.
    func testFinderUnknownKeysPreserved() throws {
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["RawQuery": "x", "SearchCriteria": ["FXScopeArrayOfPaths": ["computer"], "Z": true, "A": 3], "Future": "😀"], format: .binary, options: 0)
        let document = try FinderSavedSearchCodec.decode(bytes)
        XCTAssertTrue(document.isReadOnly)
        XCTAssertEqual(document.readOnlyReasons.count, 4)
        XCTAssertEqual(FinderSavedSearchCodec.encode(document), bytes)
    }
    /// F-043: incomplete documents fail instead of broadening.
    func testSavedSearchTruncations() throws {
        let bytes = try SavedSearchCodec.encode(SavedSearchDocument(name: "x", request: SearchRequest(text: "kind:directory")))
        for count in [0, 1, bytes.count / 2, bytes.count - 1] { XCTAssertThrowsError(try SavedSearchCodec.decode(bytes.prefix(count))) }
    }
}
