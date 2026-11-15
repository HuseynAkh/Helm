#if os(macOS)
import XCTest
import HelmAgent
import HelmCore
@testable import HelmUI

/// The status bar during a search with a model's help: its line takes the place of the usual words, and only a line
/// with the queries that ran is a button to press.
final class StatusBarAILineTests: XCTestCase {
    private let status = StatusPresentation(itemCount: 12)

    func testWithoutAnAISearchTheBarSaysTheUsualWords() {
        let bar = StatusBarView(status: status)
        XCTAssertEqual(bar.text, StatusText.format(status))
        XCTAssertFalse(bar.isPressable, "nothing to press")
    }

    func testAnAILineTakesThePlaceOfTheUsualWordsAndIsPlainWithoutQueries() {
        let line = AISearchStatus(text: AgentText.searchThinking)
        let bar = StatusBarView(status: status, aiSearch: line)
        XCTAssertEqual(bar.text, line.text, "the AI line, not the usual words")
        XCTAssertNotEqual(bar.text, StatusText.format(status))
        XCTAssertFalse(bar.isPressable, "a line with no queries has nothing to press")
    }

    func testAnAILineWithQueriesIsAButtonThatListsThem() {
        let line = AISearchStatus(text: AgentText.searchOnThisMac, queries: ["name contains “invoice”", "kind is PDF"])
        let bar = StatusBarView(status: status, aiSearch: line)
        XCTAssertEqual(bar.text, line.text)
        XCTAssertTrue(bar.isPressable)
        XCTAssertEqual(bar.queries, line.queries, "the queries it lists, in order")
    }
}
#endif
