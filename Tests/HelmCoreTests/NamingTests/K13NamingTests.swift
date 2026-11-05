// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore

final class K13NamingTests: XCTestCase {
    /// F-054, B-046: byte limit accepts exactly 255 bytes.
    func testUTF8ExactLimit() throws {
        XCTAssertEqual(try FileNameValidator.validate(String(repeating: "a", count: 255)).get().value.utf8.count, 255)
    }
    /// F-054: graphemes must still respect byte limits.
    func testEmojiByteLimit() throws {
        XCTAssertNotNil(ValidFileName(String(repeating: "😀", count: 63)))
        XCTAssertNil(ValidFileName(String(repeating: "😀", count: 64)))
    }
    /// F-055, B-047: NFC/NFD names collide.
    func testCanonicalCollision() throws {
        XCTAssertEqual(try UniqueNamer.name(for: "café.txt", existingNames: ["cafe\u{301}.txt"]).value, "café 2.txt")
    }
    /// F-055, B-047: normalization remains significant on case-sensitive volumes.
    func testCaseSensitiveCanonicalCollision() throws {
        XCTAssertEqual(FileNameComparison.key("é", caseSensitive: true), FileNameComparison.key("e\u{301}", caseSensitive: true))
        XCTAssertNotEqual(FileNameComparison.key("A", caseSensitive: true), FileNameComparison.key("a", caseSensitive: true))
    }
    /// F-054: preserve RTL and emoji filename bytes.
    func testRTLNameRoundTrip() throws {
        let name = try XCTUnwrap(ValidFileName("مرحبا😀.txt"))
        XCTAssertEqual(try JSONDecoder().decode(ValidFileName.self, from: JSONEncoder().encode(name)), name)
    }
    /// B-046: persisted names cannot bypass validation.
    func testTraversalDecodeRejected() throws {
        for raw in ["../x", ".", "..", "a/b", "a\0b"] {
            XCTAssertThrowsError(try JSONDecoder().decode(ValidFileName.self, from: JSONEncoder().encode(raw)))
        }
    }
    /// F-052, F-056: unique suffix stays within byte budget.
    func testLongCollisionTruncatesWholeGrapheme() throws {
        let raw = "aaa" + String(repeating: "😀", count: 63)
        let name = try UniqueNamer.name(for: raw, existingNames: [raw]).value
        XCTAssertEqual(name, "aaa" + String(repeating: "😀", count: 62) + " 2")
        XCTAssertLessThanOrEqual(name.utf8.count, 255)
    }
    /// F-056: skips a long contiguous collision run.
    func testManyOccupiedSuffixes() throws {
        let occupied = Set(["x.txt"] + (2...2000).map { "x \($0).txt" })
        XCTAssertEqual(try UniqueNamer.name(for: "x.txt", existingNames: occupied).value, "x 2001.txt")
    }
    /// F-055: regex metacharacters are ordinary text.
    func testReplacementIsLiteral() throws {
        XCTAssertEqual(try BatchRenameRule.findReplace(find: ".*", replacement: "$1").name(for: "a.*b.txt", index: 0, date: .distantPast), "a$1b.txt")
    }
    /// F-055, B-046: negative overflow must throw.
    func testCounterUnderflow() throws {
        XCTAssertThrowsError(try BatchRenameRule.template("[Counter]", counterStart: Int.min).name(for: "a", index: -1, date: .distantPast))
    }
    /// F-055: no inputs creates no executable steps.
    func testEmptyPlan() throws {
        let plan = BatchRenamePlanner.plan(items: [], rule: .addText(prepend: "x", append: ""))
        XCTAssertFalse(plan.canExecute)
        XCTAssertTrue(plan.steps.isEmpty)
    }
    /// B-047: aliases of the same source block the plan.
    func testNormalizedDuplicateSource() throws {
        let plan = BatchRenamePlanner.plan(items: [URL(fileURLWithPath: "/a/x"), URL(fileURLWithPath: "/a/../a/x")], rule: .template("[Counter]", counterStart: 1))
        XCTAssertFalse(plan.issues.isEmpty)
        XCTAssertTrue(plan.steps.isEmpty)
    }
}
