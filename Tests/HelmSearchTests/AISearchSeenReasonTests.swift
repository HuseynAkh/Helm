import XCTest
import HelmCore
@testable import HelmSearch

/// The reason a file a model looked at and said fits carries: "Model saw: " and the model's phrase, escaped, in place of
/// what was read on this Mac.
final class AISearchSeenReasonTests: XCTestCase {
    func testWhatAModelSawIsTheContentFact() {
        let seen = AISearchSighting(medium: .image, textWords: ["kite"], labels: ["sky"], seen: "A red kite over the sand")
        XCTAssertEqual(SearchReasonBuilder.seen(seen), "Model saw: A red kite over the sand")
        XCTAssertEqual(SearchReasonBuilder.seen(AISearchSighting(medium: .document, textWords: [], labels: [], seen: "An invoice\u{202E}")),
                       "Model saw: An invoice\\u{202E}", "a hidden character is shown, never hidden")
        XCTAssertEqual(SearchReasonBuilder.seen(AISearchSighting(medium: .document, textWords: ["plumber"], labels: [])),
                       "Mentions “plumber”")
        XCTAssertEqual(SearchReasonBuilder.seen(AISearchSighting(medium: .image, textWords: [], labels: ["dog"], seen: "")),
                       "Shows: dog", "an empty phrase leaves what was read on this Mac")
        let entry = FileEntry(url: URL(fileURLWithPath: "/home/someone/Pictures/DSC_0193.jpg"), kind: .regular, isHidden: false,
                              size: 1_000, modificationDate: Date(timeIntervalSince1970: 1_000), volumeIdentifier: "v")
        let reason = SearchReasonBuilder.reason(codes: [.content], entry: entry, query: AISearchQuery(contentAll: ["kite"]),
                                                scopeRoot: nil, calendar: .current, locale: Locale(identifier: "en_US"),
                                                sighting: seen)
        XCTAssertEqual(reason, SearchReason(codes: [.content], line: "Model saw: A red kite over the sand"))
    }
}
