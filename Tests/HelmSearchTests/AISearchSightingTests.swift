import XCTest
import HelmCore
@testable import HelmSearch

/// What AI search makes of a picture or a video that Read contents read: every word of the query seen in its text or
/// among what it shows, a label found by its own word or by a word inside it, plurals, and the line each result shows.
final class AISearchSightingTests: XCTestCase {
    private func summary(_ kind: AgentContentKind, labels: [(String, Double)] = [], text: [String] = [],
                         status: AgentContentStatus = .read) -> AgentContentSummary {
        AgentContentSummary(kind: kind, status: status,
                            labels: labels.map { AgentContentLabel(identifier: $0.0, confidence: $0.1) }, foundText: text)
    }

    func testEveryWordMustBeSeen() {
        let photo = summary(.image, labels: [("dog", 0.8), ("beach", 0.5), ("golden_retriever", 0.4)], text: ["Paid in full"])
        XCTAssertEqual(AISearchMatcher.sighting(of: ["dogs", "beach"], in: photo),
                       AISearchSighting(medium: .image, textWords: [], labels: ["dog", "beach"]))
        XCTAssertEqual(AISearchMatcher.sighting(of: ["retriever"], in: photo)?.labels, ["golden retriever"])
        XCTAssertEqual(AISearchMatcher.sighting(of: ["paid", "dog"], in: photo),
                       AISearchSighting(medium: .image, textWords: ["paid"], labels: ["dog"]))
        XCTAssertNil(AISearchMatcher.sighting(of: ["dog", "cat"], in: photo))
        XCTAssertNil(AISearchMatcher.sighting(of: [], in: photo))
    }

    func testOnlyAReadPictureOrVideoAndOnlySureLabels() {
        XCTAssertNil(AISearchMatcher.sighting(of: ["dog"], in: summary(.image, labels: [("dog", 0.2)])), "too unsure")
        XCTAssertNil(AISearchMatcher.sighting(of: ["dog"], in: summary(.image, labels: [("dog", 0.9)], status: .not_downloaded)))
        XCTAssertNil(AISearchMatcher.sighting(of: ["invoice"], in: AgentContentSummary(kind: .pdf, status: .read, lines: ["Invoice"])),
                     "documents are Spotlight's")
        XCTAssertEqual(AISearchMatcher.sighting(of: ["exit"], in: summary(.video, text: ["EXIT ONLY"]))?.medium, .video)
    }

    func testAWholeWordLabelComesFirst() {
        let sky = summary(.image, labels: [("blue_sky", 0.7), ("outdoor", 0.7), ("sky", 0.7)])
        XCTAssertEqual(AISearchMatcher.sighting(of: ["sky"], in: sky)?.labels, ["sky"])
        XCTAssertEqual(AISearchMatcher.sighting(of: ["blue"], in: sky)?.labels, ["blue sky"])
    }

    func testTheLineAResultShows() {
        XCTAssertEqual(SearchReasonBuilder.seen(AISearchSighting(medium: .image, textWords: ["invoice"], labels: [])),
                       "Text in image: “invoice”")
        XCTAssertEqual(SearchReasonBuilder.seen(AISearchSighting(medium: .video, textWords: ["beach"], labels: [])),
                       "Text in video: “beach”")
        XCTAssertEqual(SearchReasonBuilder.seen(AISearchSighting(medium: .image, textWords: [], labels: ["dog", "beach"])),
                       "Shows: dog, beach")
        XCTAssertEqual(SearchReasonBuilder.seen(AISearchSighting(medium: .image, textWords: ["paid"], labels: ["dog"])),
                       "Shows: dog · Text in image: “paid”")
        XCTAssertNil(SearchReasonBuilder.seen(AISearchSighting(medium: .image, textWords: [], labels: [])))
        // A hidden character in a label is written out.
        XCTAssertEqual(SearchReasonBuilder.seen(AISearchSighting(medium: .image, textWords: [], labels: ["d\u{200B}og"])),
                       "Shows: d\\u{200B}og")
        // The content fact of a reason names what was seen, ahead of the query's own words.
        let entry = FileEntry(url: URL(fileURLWithPath: "/home/helm/IMG_1.png"), name: "IMG_1.png", kind: .regular)
        let reason = SearchReasonBuilder.reason(codes: [.content, .kind], entry: entry, query: AISearchQuery(contentAll: ["dog"]),
                                                scopeRoot: nil, calendar: .current, locale: Locale(identifier: "en_US"),
                                                sighting: AISearchSighting(medium: .image, textWords: [], labels: ["dog"]))
        XCTAssertEqual(reason?.line, "Shows: dog · Image")
    }
}
