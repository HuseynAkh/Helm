// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmSearch

final class CriteriaHardeningTests: XCTestCase {
    func testAllRowsRoundTripAndEdits() throws {
        let rows: [SearchCriteriaRow] = [.nameContains("kind:folder OR *"), .kind(.regular), .modifiedBefore(Date(timeIntervalSince1970: 200)),
            .modifiedOnOrAfter(Date(timeIntervalSince1970: 100)), .sizeLessThan(100), .sizeGreaterThan(0), .tag("Work"), .fileExtension("txt")]
        var editor = SearchCriteriaEditor(document: SavedSearchDocument(name: "Draft", request: SearchRequest(text: "quoted", scope: .thisMac, includeHidden: true)))
        for row in rows { try editor.append(row); XCTAssertEqual(SearchCriteriaRow(clause: row.clause), row) }
        let saved = try SavedSearchCodec.decode(editor.encode())
        XCTAssertEqual(saved.request.filters, rows.map(\.clause)); XCTAssertEqual(saved.request.scope, .thisMac)
        XCTAssertTrue(saved.request.includeHidden); XCTAssertEqual(saved.request.text, "quoted")
        XCTAssertEqual(SearchCriteriaEditor(document: saved).rows, rows)
        try editor.replace(at: 0, with: .nameContains("new")); try editor.remove(at: 1)
        XCTAssertEqual(editor.rows.first, .nameContains("new")); XCTAssertEqual(editor.rows.count, 7)
        XCTAssertThrowsError(try editor.replace(at: -1, with: .tag("x")))
        XCTAssertThrowsError(try editor.remove(at: 100))
    }
    func testOpaqueRawQueryReadOnlyAndBytePreservation() throws {
        let original = try FinderSavedSearchDocument(rawQuery: "TRUEPREDICATE OR $x == '*'", searchScopes: ["/tmp"])
        var editor = SearchCriteriaEditor(opaqueDocument: original)
        XCTAssertTrue(editor.isReadOnly); XCTAssertTrue(editor.rows.isEmpty)
        XCTAssertEqual(try editor.encode(), FinderSavedSearchCodec.encode(original))
        XCTAssertThrowsError(try editor.append(.nameContains("new")))
        XCTAssertThrowsError(try editor.replace(at: 0, with: .kind(.directory)))
        XCTAssertThrowsError(try editor.remove(at: 0)); XCTAssertThrowsError(try editor.savedDocument())
    }
    func testTypedFilterValidationAndBounds() throws {
        for clause: SearchClause in [.sizeLessThan(-1), .sizeGreaterThan(-1), .name(""), .tag(""), .ext(""), .before(Date(timeIntervalSince1970: .infinity))] {
            XCTAssertThrowsError(try SearchQueryParser.compile(SearchRequest(text: "", filters: [clause])))
        }
        XCTAssertThrowsError(try SearchQueryParser.compile(SearchRequest(text: "", filters: Array(repeating: .kind(.regular), count: 257))))
        for input in [String(repeating: "a", count: 10000), String(repeating: "😀", count: 2500)] {
            XCTAssertThrowsError(try SearchQueryParser.tokenize(input)) { XCTAssertEqual($0 as? SearchParseError, .tooLong) }
        }
        XCTAssertEqual(try SearchQueryParser.tokenize(String(repeating: "a", count: 4096)).count, 1)
    }
    func testUnicodeRankingUsesSameFoldAsMatching() {
        XCTAssertEqual(SearchRanker.nameMatch("cafe\u{301}", query: "CAFÉ"), .exact)
        XCTAssertEqual(SearchRanker.nameMatch("CAFETERIA", query: "café"), .prefix)
        XCTAssertEqual(SearchRanker.nameMatch("my-café", query: "CAFE"), .wordBoundary)
        XCTAssertEqual(SearchRanker.nameMatch("xcafé", query: "CAFE"), .substring)
    }
    func testUnicodeQuotesEscapesAndOperators() throws {
        XCTAssertEqual(try SearchQueryParser.tokenize("مرحبا\u{2003}\"世界 😀\" cafe\u{301}"), ["مرحبا", "世界 😀", "cafe\u{301}"])
        XCTAssertEqual(try SearchQueryParser.tokenize(#"a\ b "c\"d" e\\f"#), ["a b", "c\"d", "e\\f"])
        for literal in ["OR", "AND", "NOT", "contents:secret", "name:foo", "!=", "*", "[cd]", "foo||bar"] {
            XCTAssertEqual(try SearchQueryParser.compile(SearchRequest(text: literal)).clauses, [.name(literal)])
        }
        let folded = try SearchQueryParser.compile(SearchRequest(text: "CAFÉ"))
        XCTAssertTrue(folded.matches(FileEntry(url: URL(fileURLWithPath: "/cafe\u{301}"))))
        XCTAssertEqual(try SearchQueryParser.compile(SearchRequest(text: "KIND:SYMLINKTODIRECTORY")).clauses, [.kind(.symlinkToDirectory)])
    }
    func testSeededLiteralRoundTripsAndMalformedInputs() throws {
        var seed: UInt64 = 0x4b26
        let alphabet = Array("abé中😀 :*\\\"\t\n")
        for _ in 0..<500 {
            seed = seed &* 6364136223846793005 &+ 1
            let length = Int(seed % 60) + 1
            var text = ""
            for _ in 0..<length {
                seed = seed &* 6364136223846793005 &+ 1
                text.append(alphabet[Int(seed % UInt64(alphabet.count))])
            }
            let quoted = "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
            XCTAssertEqual(try SearchQueryParser.tokenize(quoted), [text])
            XCTAssertThrowsError(try SearchQueryParser.tokenize(quoted + "\\"))
            XCTAssertThrowsError(try SearchQueryParser.tokenize(quoted + "\""))
            let document = SavedSearchDocument(name: text, request: SearchRequest(text: "", filters: [.name(text)]))
            XCTAssertEqual(try SavedSearchCodec.decode(SavedSearchCodec.encode(document)), document)
        }
    }
}
