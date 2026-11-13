import XCTest
import HelmCore

/// Hidden and control characters are shown as escapes, decided by Unicode class and not from a list.
final class AgentTextEscaperTests: XCTestCase {
    private func scalar(_ value: UInt32) -> String {
        guard let scalar = Unicode.Scalar(value) else { XCTFail("U+\(String(value, radix: 16)) isn't a scalar"); return "" }
        return String(scalar)
    }
    private func escaped(_ value: UInt32) -> String { "\\u{\(String(value, radix: 16, uppercase: true))}" }

    /// One row per class the escaper covers, with scalars that have slipped past list-based filters.
    private let table: [(name: String, scalars: [UInt32])] = [
        ("Cc: control", [0x00, 0x07, 0x09, 0x0A, 0x0D, 0x1B, 0x7F, 0x85, 0x9F]),
        ("Cf: bidirectional controls", [0x061C, 0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]),
        ("Cf: zero width and other format", [0x00AD, 0x200B, 0x200C, 0x2060, 0x2061, 0x2064, 0xFEFF, 0x180E, 0xFFF9, 0xFFFA, 0xFFFB]),
        ("Zl and Zp: line and paragraph separators", [0x2028, 0x2029]),
        ("Co: private use", [0xE000, 0xF8FF, 0xF0000, 0x10FFFD]),
        ("Cn: unassigned", [0x0378, 0xFFFF, 0x1FFFE, 0xEFFFF]),
        ("default ignorable: variation selectors", [0xFE00, 0xFE01, 0xFE0E, 0xFE0F, 0xE0100, 0xE01EF, 0x180B, 0x180D]),
        ("default ignorable: blank fillers and joiners", [0x034F, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x3164, 0xFFA0]),
        ("default ignorable: tag characters", [0xE0001, 0xE0020, 0xE0041, 0xE007A, 0xE007F])
    ]

    func testEveryHiddenClassIsEscaped() {
        for row in table {
            for value in row.scalars {
                let text = "a" + scalar(value) + "b"
                XCTAssertEqual(AgentTextEscaper.escape(text), "a" + escaped(value) + "b", "\(row.name): U+\(String(value, radix: 16))")
                XCTAssertFalse(AgentTextEscaper.isClean(text), "\(row.name): U+\(String(value, radix: 16))")
                // On its own, first and last, it is escaped just the same.
                XCTAssertEqual(AgentTextEscaper.escape(scalar(value)), escaped(value), row.name)
            }
        }
    }

    func testTheEscapeIsTheScalarsNumberInUpperCaseHex() {
        XCTAssertEqual(AgentTextEscaper.escape("a\u{2028}b"), "a\\u{2028}b")
        XCTAssertEqual(AgentTextEscaper.escape("a\u{2029}b"), "a\\u{2029}b")
        XCTAssertEqual(AgentTextEscaper.escape("soft\u{AD}hyphen"), "soft\\u{AD}hyphen")
        XCTAssertEqual(AgentTextEscaper.escape("line\nbreak\ttab"), "line\\u{A}break\\u{9}tab")
        XCTAssertEqual(AgentTextEscaper.escape("\u{061C}"), "\\u{61C}")
        XCTAssertEqual(AgentTextEscaper.escape("\u{E0041}"), "\\u{E0041}")
        // A name that reads "invoice.exe" backwards is shown for what it is.
        XCTAssertEqual(AgentTextEscaper.escape("invoice\u{202E}fdp.exe"), "invoice\\u{202E}fdp.exe")
        // Several in a row are each escaped.
        XCTAssertEqual(AgentTextEscaper.escape("\u{200B}\u{200B}\u{FEFF}"), "\\u{200B}\\u{200B}\\u{FEFF}")
    }

    func testOrdinaryTextIsLeftAlone() {
        let ordinary = ["", "Report 2026.pdf", "Ünïcödé façade.txt", "e\u{301}cole", "日本語のファイル", "한국어", "עברית", "العربية",
                        "a b\u{A0}c", "50% off — “today” … ‘now’", "tab-less_name.v1.2", "😀 🎉 🇨🇦", "👍🏽", "\\u{202E} typed out"]
        for text in ordinary {
            XCTAssertEqual(AgentTextEscaper.escape(text), text, text)
            XCTAssertTrue(AgentTextEscaper.isClean(text), text)
        }
    }

    func testAnEmojiJoinerIsKept() {
        let family = "👨\u{200D}👩\u{200D}👧"
        XCTAssertEqual(AgentTextEscaper.escape(family), family)
        XCTAssertTrue(AgentTextEscaper.isClean(family))
        XCTAssertEqual(AgentTextEscaper.escape("Trip \(family).jpg"), "Trip \(family).jpg")
        // With a skin tone, and with the selector that asks for the picture form before the joiner.
        let astronaut = "👩🏽\u{200D}🚀", flag = "🏳\u{FE0F}\u{200D}🌈", heart = "❤\u{FE0F}\u{200D}🔥"
        for emoji in [astronaut, flag, heart, "❤\u{FE0F}🔥"] {
            XCTAssertEqual(AgentTextEscaper.escape(emoji), emoji, emoji)
            XCTAssertTrue(AgentTextEscaper.isClean(emoji), emoji)
        }
    }

    func testAJoinerOrSelectorThatIsNotBetweenEmojiIsEscaped() {
        // Beside letters and digits, a joiner hides inside ordinary text.
        XCTAssertEqual(AgentTextEscaper.escape("pay\u{200D}pal"), "pay\\u{200D}pal")
        XCTAssertEqual(AgentTextEscaper.escape("1\u{200D}2"), "1\\u{200D}2")
        XCTAssertEqual(AgentTextEscaper.escape("a\u{FE0F}b"), "a\\u{FE0F}b")
        XCTAssertEqual(AgentTextEscaper.escape("1\u{FE0F}2"), "1\\u{FE0F}2")
        // At an edge there is an emoji on one side only.
        XCTAssertEqual(AgentTextEscaper.escape("👨\u{200D}"), "👨\\u{200D}")
        XCTAssertEqual(AgentTextEscaper.escape("\u{200D}👨"), "\\u{200D}👨")
        XCTAssertEqual(AgentTextEscaper.escape("👨\u{200D}a"), "👨\\u{200D}a")
        XCTAssertEqual(AgentTextEscaper.escape("a\u{200D}👨"), "a\\u{200D}👨")
        XCTAssertEqual(AgentTextEscaper.escape("❤\u{FE0F}"), "❤\\u{FE0F}")
        XCTAssertEqual(AgentTextEscaper.escape("❤\u{FE0F} NY"), "❤\\u{FE0F} NY")
        // Only the shapes emoji are written with are kept, so a run of them can't carry anything.
        XCTAssertEqual(AgentTextEscaper.escape("👨\u{200D}\u{200D}👩"), "👨\\u{200D}\\u{200D}👩")
        XCTAssertEqual(AgentTextEscaper.escape("❤\u{FE0F}\u{FE0F}🔥"), "❤\\u{FE0F}\\u{FE0F}🔥")
        XCTAssertEqual(AgentTextEscaper.escape("👨\u{200D}\u{FE0F}👩"), "👨\\u{200D}\\u{FE0F}👩")
        // Any other selector is escaped even between emoji.
        XCTAssertEqual(AgentTextEscaper.escape("👨\u{FE0E}👩"), "👨\\u{FE0E}👩")
        XCTAssertEqual(AgentTextEscaper.escape("👨\u{200B}👩"), "👨\\u{200B}👩")
    }

    func testIsCleanAgreesWithEscape() {
        var samples = ["plain", "👨\u{200D}👩", "a\u{200D}b", "x\u{2028}y", "❤\u{FE0F}", "\u{E0041}"]
        samples += table.flatMap { $0.scalars.map { "n" + scalar($0) } }
        for text in samples {
            XCTAssertEqual(AgentTextEscaper.isClean(text), AgentTextEscaper.escape(text) == text, text.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "))
        }
    }

    func testEscapedTextIsCleanAndEscapingTwiceChangesNothing() {
        for row in table {
            let text = row.scalars.map { "w" + scalar($0) }.joined()
            let once = AgentTextEscaper.escape(text)
            XCTAssertTrue(AgentTextEscaper.isClean(once), row.name)
            XCTAssertEqual(AgentTextEscaper.escape(once), once, row.name)
            XCTAssertFalse(once.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }, row.name)
        }
    }
}
