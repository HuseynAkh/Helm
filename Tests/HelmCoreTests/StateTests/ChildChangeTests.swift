import XCTest
import Foundation
import HelmCore

/// The list moves only the rows that changed inside an open folder, so the diff has to be exact.
final class ChildChangeTests: XCTestCase {
    private func ids(_ names: String...) -> [ItemID] { names.map { ItemID(rawValue: "/folder/" + $0) } }

    func testFirstListingInsertsEveryRow() {
        XCTAssertEqual(SnapshotDiff.childChange(from: [], to: ids("a", "b", "c")),
                       ChildChange(removed: [], inserted: [0, 1, 2]))
    }
    func testSameListingChangesNothing() {
        // What keeps a folder that's opened again from rebuilding when its fresh listing arrives.
        let change = SnapshotDiff.childChange(from: ids("a", "b"), to: ids("a", "b"))
        XCTAssertEqual(change, ChildChange(removed: [], inserted: []))
        XCTAssertEqual(change?.isEmpty, true)
    }
    func testAddedAndRemovedRows() {
        XCTAssertEqual(SnapshotDiff.childChange(from: ids("a", "b", "c"), to: ids("a", "c", "d")),
                       ChildChange(removed: [1], inserted: [2]))
    }
    func testClosingRemovesEveryRow() {
        XCTAssertEqual(SnapshotDiff.childChange(from: ids("a", "b"), to: []), ChildChange(removed: [0, 1], inserted: []))
    }
    func testReorderAsksForAReload() {
        XCTAssertNil(SnapshotDiff.childChange(from: ids("a", "b"), to: ids("b", "a")))
        XCTAssertNil(SnapshotDiff.childChange(from: ids("a", "b", "c"), to: ids("c", "x", "a")))
    }
    func testRepeatedItemsAskForAReload() {
        XCTAssertNil(SnapshotDiff.childChange(from: ids("a", "a"), to: ids("a")))
        XCTAssertNil(SnapshotDiff.childChange(from: ids("a"), to: ids("a", "b", "a")))
    }

    /// Removing at old indexes (from the end) and then inserting at new ones (from the start), as an outline view
    /// does inside one batch, always gives the new listing.
    func testApplyingTheChangeGivesTheNewOrder() {
        var random = SeededGenerator(seed: 0x5EED)
        for round in 0..<300 {
            let old = (0..<Int.random(in: 0...12, using: &random)).map { ItemID(rawValue: "/f/old-\(round)-\($0)") }
            var new = old.filter { _ in Bool.random(using: &random) }
            for fresh in 0..<Int.random(in: 0...6, using: &random) {
                new.insert(ItemID(rawValue: "/f/new-\(round)-\(fresh)"), at: Int.random(in: 0...new.count, using: &random))
            }
            guard let change = SnapshotDiff.childChange(from: old, to: new) else { return XCTFail("round \(round) had no change") }
            var rows = old
            for index in change.removed.reversed() { rows.remove(at: index) }
            for index in change.inserted { rows.insert(new[index], at: index) }
            XCTAssertEqual(rows, new, "round \(round)")
        }
    }
}

/// A small deterministic generator, so a failure always repeats.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
