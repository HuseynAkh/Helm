import Foundation
import XCTest
import HelmCore
import HelmTestKit

final class TextTests: XCTestCase {
    func testDecimalAndBinarySizes() {
        for (bytes, expected) in [(Int64(0), "0 bytes"), (1, "1 byte"), (999, "999 bytes"),
                                   (1000, "1 KB"), (1500, "1.5 KB"), (999_999, "1 MB"),
                                   (-1500, "-1.5 KB"), (Int64.max, "9.2 EB"), (Int64.min, "-9.2 EB")] {
            XCTAssertEqual(ByteCountText.format(bytes), expected)
        }
        XCTAssertEqual(ByteCountText.format(1024, style: .binary), "1 KiB")
        XCTAssertEqual(ByteCountText.format(1536, style: .binary), "1.5 KiB")
        XCTAssertEqual(ByteCountText.format(1_048_576, style: .binary), "1 MiB")
        XCTAssertEqual(ByteCountText.formatExact(0), "0 bytes")
        XCTAssertEqual(ByteCountText.formatExact(1234567), "1,234,567 bytes")
        XCTAssertEqual(ByteCountText.formatExact(Int64.min), "-9,223,372,036,854,775,808 bytes")
    }

    func testStatusText() {
        XCTAssertEqual(StatusText.format(itemCount: 1), "1 item")
        XCTAssertEqual(StatusText.format(itemCount: 0), "0 items")
        XCTAssertEqual(StatusText.format(itemCount: 2, selectedCount: 1, freeBytes: 1500), "2 items  •  1 selected  •  1.5 KB free")
        XCTAssertEqual(StatusText.format(itemCount: 3, selectedCount: 2, selectedBytes: 2048, freeBytes: 0, style: .binary), "3 items  •  2 selected  •  2 KiB  •  0 bytes free")
        XCTAssertEqual(StatusText.format(itemCount: -1, selectedCount: -1, selectedBytes: 20, freeBytes: -1), "0 items")
        XCTAssertEqual(StatusText.format(itemCount: 2, selectedCount: 1, selectedBytes: -1), "2 items  •  1 selected")
    }

    func testIncrementalTypingTimeoutAndReset() {
        let clock = FakeClock()
        var select = TypeSelect(clock: clock)
        let names = ["apple", "apricot", "banana", "a space"]
        XCTAssertFalse(select.isActive)
        XCTAssertEqual(select.select(typing: "a", names: names), 0)
        clock.advance(by: 0.5)
        XCTAssertEqual(select.select(typing: "p", names: names), 0)
        XCTAssertEqual(select.select(typing: "r", names: names), 1)
        XCTAssertEqual(select.prefix, "apr")
        XCTAssertTrue(select.isActive)
        clock.advance(by: 1)
        XCTAssertFalse(select.isActive)
        XCTAssertEqual(select.select(typing: "b", names: names), 2)
        select.reset()
        XCTAssertFalse(select.isActive)
        XCTAssertEqual(select.prefix, "")
        XCTAssertEqual(select.select(typing: "a", names: names), 0)
        XCTAssertEqual(select.select(typing: " ", names: names), 3)
    }

    func testUnicodeMatchingAndInvalidInput() {
        XCTAssertEqual(TypeSelect.match(prefix: "É", names: ["other", "e\u{301}clair"]), 1)
        XCTAssertEqual(TypeSelect.match(prefix: "😀", names: ["😀 photo"]), 0)
        XCTAssertEqual(TypeSelect.match(prefix: "مر", names: ["مرحبا"]), 0)
        XCTAssertNil(TypeSelect.match(prefix: "", names: ["a"]))
        XCTAssertNil(TypeSelect.match(prefix: "z", names: []))
        let clock = FakeClock()
        var select = TypeSelect(clock: clock, timeout: .nan)
        XCTAssertEqual(select.timeout, 1)
        XCTAssertNil(select.select(typing: "\n", names: ["a"]))
        XCTAssertNil(select.select(typing: "", names: ["a"]))
        XCTAssertEqual(select.prefix, "")
        XCTAssertNil(select.select(typing: "z", names: ["a"]))
        XCTAssertTrue(select.isActive)
        clock.advance(by: -1)
        XCTAssertFalse(select.isActive)
        XCTAssertEqual(select.select(typing: "a", names: ["a"]), 0)
    }
}
