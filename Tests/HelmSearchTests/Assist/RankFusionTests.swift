import XCTest
import HelmCore
@testable import HelmSearch

/// Weighted reciprocal rank fusion: what rises, how ties fall, and what the weights do.
final class RankFusionTests: XCTestCase {
    private func id(_ name: String) -> ItemID { ItemID(url: URL(fileURLWithPath: "/home/helm/\(name)")) }
    private func ids(_ names: String...) -> [ItemID] { names.map(id) }

    func testTheConstantsAreTheDesigns() {
        XCTAssertEqual(RankFusion.k, 60)
        XCTAssertEqual(RankFusion.queryWeights, [1.0, 0.85, 0.7, 0.6, 0.5, 0.5])
        XCTAssertEqual(RankFusion.baselineWeight, 0.5)
    }

    func testAnItemInSeveralListsRisesAboveOneThatTopsASingleList() {
        let fused = RankFusion.fuse([(1.0, ids("a", "b", "c")), (1.0, ids("d", "b", "c")), (1.0, ids("e", "c", "b"))])
        XCTAssertEqual(Array(fused.prefix(2)), ids("b", "c"), "b and c are in every list")
        XCTAssertEqual(Set(fused), Set(ids("a", "b", "c", "d", "e")), "every item once")
        XCTAssertEqual(fused.count, 5)
    }

    func testOneListKeepsItsOrder() {
        XCTAssertEqual(RankFusion.fuse([(0.7, ids("x", "y", "z"))]), ids("x", "y", "z"))
    }

    func testTiesKeepTheOrderTheyWereFirstSeen() {
        // a and c have the same score: first in one list each, with the same weight.
        let fused = RankFusion.fuse([(1.0, ids("a")), (1.0, ids("c")), (1.0, ids("b"))])
        XCTAssertEqual(fused, ids("a", "c", "b"))
        let reversed = RankFusion.fuse([(1.0, ids("b")), (1.0, ids("c")), (1.0, ids("a"))])
        XCTAssertEqual(reversed, ids("b", "c", "a"))
    }

    func testAHeavierListWins() {
        let strict = RankFusion.fuse([(1.0, ids("strict")), (0.5, ids("loose"))])
        XCTAssertEqual(strict, ids("strict", "loose"))
        let swapped = RankFusion.fuse([(0.5, ids("strict")), (1.0, ids("loose"))])
        XCTAssertEqual(swapped, ids("loose", "strict"))
    }

    func testTheScoreIsWeightOverKPlusPlace() {
        // Second place in a list of weight 1 (1/62) beats first place in a list of weight 0.5 (0.5/61), but third place
        // with weight 0.5 in two lists (2 × 0.5/63) beats second place with weight 0.5 in one.
        let fused = RankFusion.fuse([(1.0, ids("top", "second")), (0.5, ids("half"))])
        XCTAssertEqual(fused, ids("top", "second", "half"))
        let twice = RankFusion.fuse([(0.5, ids("p", "q", "both")), (0.5, ids("r", "s", "both"))])
        XCTAssertEqual(twice.first, id("both"))
    }

    func testAnItemRepeatedInOneListCountsOnce() {
        let fused = RankFusion.fuse([(1.0, ids("a", "b", "a", "a")), (1.0, ids("b"))])
        XCTAssertEqual(fused, ids("b", "a"), "a's later places in its own list add nothing")
    }

    func testNoListsGiveNothing() {
        XCTAssertEqual(RankFusion.fuse([]), [])
        XCTAssertEqual(RankFusion.fuse([(1.0, [])]), [])
    }
}
