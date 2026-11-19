import XCTest
import Foundation
import HelmCore
import HelmFileSystem
@testable import HelmSearch

/// AI search's ranking: what's near the folder searched comes before what's buried, for an equal match, and the
/// person's own words count. Plain search, which sets neither, keeps the frozen weights (`SearchTests`).
final class SearchProximityTests: XCTestCase {
    private struct Clock: HelmClock { func now() -> Date { Date(timeIntervalSince1970: 10_000_000) } }
    private let root = URL(fileURLWithPath: "/Home/User/Projects")
    private func context(_ text: String = "", limit: Int = 300, near: Bool = true, request: String = "") -> SearchRankingContext {
        SearchRankingContext(query: SearchQuery(text: text, scope: .currentFolder(root), bookmarkPaths: [],
                                                homeDirectory: URL(fileURLWithPath: "/Home/User"), lastDirectory: nil,
                                                showHidden: false, limit: limit),
                             preferredRoots: [], proximityRoot: near ? root : nil,
                             requestWords: SearchRanker.requestWords(request))
    }
    private func candidate(_ path: String, date: Date = .distantPast) -> SearchCandidate {
        SearchCandidate(entry: FileEntry(url: URL(fileURLWithPath: path), kind: .regular, modificationDate: date))
    }
    private func ranked(_ values: [SearchCandidate], _ context: SearchRankingContext) -> [String] {
        SearchRanker.rank(values, context: context, clock: Clock()).results.map(\.entry.url.path)
    }

    func testTheBonusFallsAFolderAtATime() {
        XCTAssertEqual((0...6).map { SearchRanker.proximityBonus(depth: $0) }, [250, 200, 150, 100, 50, 0, 0])
        XCTAssertEqual(SearchRanker.depth(of: root.appendingPathComponent("a.txt"), below: root), 0)
        XCTAssertEqual(SearchRanker.depth(of: root.appendingPathComponent("x/y/a.txt"), below: root), 2)
        XCTAssertNil(SearchRanker.depth(of: root, below: root))
        XCTAssertNil(SearchRanker.depth(of: URL(fileURLWithPath: "/Home/User/Projects2/a.txt"), below: root))
    }

    func testANearFileComesBeforeABuriedOneThatMatchesAsWell() {
        let deep = candidate("/Home/User/Projects/old/2019/archive/budget.xlsx", date: Clock().now())
        let near = candidate("/Home/User/Projects/budget.xlsx")
        XCTAssertEqual(ranked([deep, near], context("budget")).first, near.entry.url.path)
        // Without a folder to measure from, the newer, deeper one wins on its date, as plain search ranks.
        XCTAssertEqual(ranked([deep, near], context("budget", near: false)).first, deep.entry.url.path)
    }

    func testNearnessIsWorthLessThanAStepOfNameMatch() {
        // Right in the folder, a name with the words inside it stays below a name that starts with them, five
        // folders down.
        let nearInside = candidate("/Home/User/Projects/my budget.txt")
        let deepPrefix = candidate("/Home/User/Projects/a/b/c/d/e/budget plan.txt")
        XCTAssertEqual(ranked([nearInside, deepPrefix], context("budget")).first, deepPrefix.entry.url.path)
    }

    func testABetterNameMatchStillWinsFromDeepDown() {
        let deepExact = candidate("/Home/User/Projects/a/b/c/d/e/budget")
        let nearInside = candidate("/Home/User/Projects/old budget notes.txt")
        XCTAssertEqual(ranked([nearInside, deepExact], context("budget")).first, deepExact.entry.url.path)
    }

    func testTheRequestsOwnWordsCount() {
        XCTAssertEqual(SearchRanker.requestWords("Photos of my DOG at the Béach, the dog!"), ["dog", "beach"])
        let named = candidate("/Home/User/Projects/x/Beach Day.jpg")
        let other = candidate("/Home/User/Projects/x/Longbeach.jpg")
        let words = context(request: "photos of my dog at the beach")
        let base = context()
        XCTAssertEqual(SearchRanker.score(named, context: words, now: Clock().now())
                       - SearchRanker.score(named, context: base, now: Clock().now()), SearchRanker.requestWordBonus)
        // A word counts where it starts a word of the name, not inside one.
        XCTAssertEqual(SearchRanker.score(other, context: words, now: Clock().now()),
                       SearchRanker.score(other, context: base, now: Clock().now()))
    }

    func testAListingWithNoWordsGoesAFolderAtATime() {
        let now = Clock().now()
        let values = [candidate("/Home/User/Projects/a/new.mov", date: now),
                      candidate("/Home/User/Projects/old.mov"),
                      candidate("/Elsewhere/system.mov", date: now),
                      candidate("/Home/User/Projects/recent.mov", date: now.addingTimeInterval(-60)),
                      candidate("/Home/User/Projects/old.mov")]
        let listed = SearchRanker.nearestFirst(values, below: root, limit: 10)
        XCTAssertEqual(listed.map(\.entry.name), ["recent.mov", "old.mov", "new.mov", "system.mov"])
        XCTAssertEqual(listed.map(\.rank), [0, 1, 2, 3])
        XCTAssertEqual(SearchRanker.nearestFirst(values, below: root, limit: 2).count, 2)
    }

    func testNothingNearIsDroppedByDateBeforeScoring() {
        var values = (0..<500).map { candidate("/Home/User/Projects/deep/a/b/c/d/e/f/report\($0)", date: Clock().now()) }
        values.append(candidate("/Home/User/Projects/report-old"))
        let batch = SearchRanker.rank(values, context: context("report", limit: 1), clock: Clock())
        XCTAssertEqual(batch.results.first?.entry.name, "report-old")
        XCTAssertFalse(batch.candidateLimitReached)
        XCTAssertEqual(batch.consideredCount, 501)
    }
}
