// DRAFT: pending review, 2026-11-05
import Foundation
import XCTest
import HelmCore
@testable import HelmSearch

/// OK1-7: incomplete input while typing is a literal filename search; the strict grammar is unchanged.
final class OP1TypingPolicyTests: XCTestCase {
    private func query(_ text: String, filters: [SearchClause] = []) -> SearchQuery {
        var value = SearchQuery(text: text, scope: .home, bookmarkPaths: [], homeDirectory: URL(fileURLWithPath: "/home"),
                                lastDirectory: nil, showHidden: false, limit: 10)
        value.filters = filters
        return value
    }
    func testIncompleteInputBecomesALiteralName() throws {
        for text in ["\"open", "tail\\", "kind:", "kind:nope", "ext:", "tag:", "size:", "before:today.txt", "report size:>"] {
            let normalized = SearchQueryParser.normalizedForTyping(query(text))
            XCTAssertEqual(normalized.filters, [.name(text)], text)
            XCTAssertEqual(normalized.text, "", text)
            XCTAssertEqual(try SearchQueryParser.compile(SearchRequest(query: normalized)).clauses, [.name(text)], text)
        }
    }
    func testStrictCompileStillRejectsTheSameInput() {
        for text in ["\"open", "tail\\", "kind:nope", "ext:", "before:2026-02-30"] {
            XCTAssertThrowsError(try SearchQueryParser.compile(SearchRequest(text: text)), text)
        }
    }
    func testCompleteQueriesAreUnchanged() throws {
        for text in ["report", "kind:folder", "\"Quarter Report\" ext:pdf"] {
            let normalized = SearchQueryParser.normalizedForTyping(query(text))
            XCTAssertEqual(normalized.text, text)
            XCTAssertTrue(normalized.filters.isEmpty)
        }
    }
    func testNonGrammarFailuresAreNotBroadenedIntoALiteral() {
        let oversized = String(repeating: "x", count: 4097)
        XCTAssertEqual(SearchQueryParser.normalizedForTyping(query(oversized)).text, oversized)
        let invalidExplicit = query("\"open", filters: [.tag("")])
        XCTAssertEqual(SearchQueryParser.normalizedForTyping(invalidExplicit).text, "\"open",
                       "An invalid explicit filter must still reach the strict failure")
    }
    func testDriverSearchesLiterallyAndKeepsTheTypedText() async {
        let invoked = expectation(description: "source receives the literal form")
        let driver = SearchSessionDriver(source: { received in
            XCTAssertEqual(received.filters, [.name("\"open")])
            invoked.fulfill()
            return AsyncThrowingStream { $0.finish() }
        })
        await driver.start(query("\"open"))
        await fulfillment(of: [invoked], timeout: 2)
        let state = await driver.state
        XCTAssertNil(state.error)
        XCTAssertEqual(state.query?.text, "\"open")
        await driver.shutdown()
    }
    func testDriverReportsAPlainMessageNotACaseName() async {
        let driver = SearchSessionDriver(source: { _ in
            XCTFail("An oversized query must not reach the source")
            return AsyncThrowingStream { $0.finish() }
        })
        await driver.start(query(String(repeating: "x", count: 4097)))
        let state = await driver.state
        XCTAssertEqual(state.error, SearchParseError.tooLong.userMessage)
        await driver.shutdown()
    }
}
