// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore

final class K13TextTests: XCTestCase {
    /// F-064: Int64 minimum does not overflow.
    func testMinimumExactBytes() throws {
        XCTAssertEqual(ByteCountText.formatExact(Int64.min), "-9,223,372,036,854,775,808 bytes")
    }
    /// F-064: rounding at a unit edge is coherent.
    func testDecimalRoundingPromotesUnit() throws {
        XCTAssertEqual(ByteCountText.format(999_999), "1 MB")
    }
    /// F-064: IEC boundary and negative signs.
    func testBinaryBoundary() throws {
        XCTAssertEqual(ByteCountText.format(1023, style: .binary), "1023 bytes")
        XCTAssertEqual(ByteCountText.format(-1024, style: .binary), "-1 KiB")
    }
    /// F-064: negative metadata stays absent.
    func testStatusUnknownMetadata() throws {
        XCTAssertEqual(StatusText.format(itemCount: -1, selectedCount: -1, selectedBytes: -1, freeBytes: -1), "0 items")
    }
    /// F-041: composed/decomposed names match.
    func testCanonicalTypeSelect() throws {
        XCTAssertEqual(TypeSelect.match(prefix: "CAFÉ", names: ["other", "cafe\u{301}.txt"]), 1)
    }
    /// F-041: RTL prefix matches without reordering.
    func testRTLTypeSelect() throws {
        XCTAssertEqual(TypeSelect.match(prefix: "مر", names: ["abc", "مرحبا"]), 1)
    }
    /// F-041: ZWJ emoji prefix remains intact.
    func testEmojiTypeSelect() throws {
        XCTAssertEqual(TypeSelect.match(prefix: "👩‍💻", names: ["👩", "👩‍💻 notes"]), 1)
    }
    /// F-041: invalid timer inputs use the default.
    func testInvalidTimeouts() throws {
        for timeout in [Double.nan, .infinity, -.infinity, 0, -1] {
            XCTAssertEqual(TypeSelect(timeout: timeout).timeout, 1)
        }
    }
    /// F-041, B-060: control input cannot corrupt a typing run.
    func testControlInputPreservesPrefix() throws {
        var selector = TypeSelect()
        XCTAssertEqual(selector.select(typing: "a", names: ["abc"]), 0)
        XCTAssertNil(selector.select(typing: "\n", names: ["abc"]))
        XCTAssertEqual(selector.prefix, "a")
    }
    /// F-041: large input fails cleanly.
    func testHugeNonMatchingPrefix() throws {
        XCTAssertNil(TypeSelect.match(prefix: String(repeating: "x", count: 100_000), names: ["x", "😀"]))
    }
}
