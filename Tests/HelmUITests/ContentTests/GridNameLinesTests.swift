#if os(macOS)
import AppKit
import XCTest
@testable import HelmUI

/// The grid's rule for long names: a name, a width and a font in, the lines on show out. A name that fits is shown
/// whole; one that doesn't gets one cut in the middle of its last line, keeping its start and its end.
@MainActor final class GridNameLinesTests: XCTestCase {
    /// Every character of a fixed-width font is as wide as the next, the ellipsis too, so the exact answers below
    /// are plain to check by counting: each line has room for 10 characters.
    private let mono = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    private var tenCharacters: CGFloat { GridNameShortener.measure("x", mono) * 10.5 }
    private func lines(_ name: String, _ maxLines: Int = 2) -> [String] {
        GridNameShortener.lines(for: name, width: tenCharacters, font: mono, maxLines: maxLines).lines
    }

    // MARK: Exact lines

    func testTheFontIsFixedWidth() {
        XCTAssertEqual(GridNameShortener.measure("…", mono), GridNameShortener.measure("x", mono), accuracy: 0.01)
        XCTAssertEqual(GridNameShortener.measure("WWWWWWWWWW", mono), GridNameShortener.measure("x", mono) * 10, accuracy: 0.01)
    }

    func testANameThatFitsIsShownWhole() {
        XCTAssertEqual(lines("notes.txt"), ["notes.txt"])
        XCTAssertEqual(lines("exactly10c"), ["exactly10c"])
        // Two lines, wrapped where the words break.
        XCTAssertEqual(lines("Two words.md"), ["Two", "words.md"])
        XCTAssertEqual(lines("abcdefghijKLMNOPQRST"), ["abcdefghij", "KLMNOPQRST"])
        // An ending too long to keep whole on a line still isn't shortened when the name fits in two lines.
        XCTAssertEqual(lines("photo.download"), ["photo.down", "load"])
        XCTAssertFalse(GridNameShortener.lines(for: "Two words.md", width: tenCharacters, font: mono, maxLines: 2).isShortened)
    }

    func testALongerNameIsCutInTheMiddleOfItsSecondLine() {
        // The first line is the start of the name; the second has more of the start, then the end, extension included.
        XCTAssertEqual(lines("Quarterly_Report_draft_v2_final.pdf"), ["Quarterly_", "Repor….pdf"])
        XCTAssertEqual(lines("The quick brown fox jumps.txt"), ["The quick", "brown….txt"])
        XCTAssertEqual(lines("Annual report.xlsx"), ["Annual", "repo….xlsx"])
        // Without an extension, the start and the end get half the line each.
        XCTAssertEqual(lines("abcdefghijKLMNOPQRSTu"), ["abcdefghij", "KLMNO…RSTu"])
        XCTAssertEqual(lines("Version 2.0 final notes for everyone"), ["Version", "2.0 f…yone"])
        XCTAssertTrue(GridNameShortener.lines(for: "Annual report.xlsx", width: tenCharacters, font: mono, maxLines: 2).isShortened)
    }

    func testSelectedNamesTakeUpToFiveLines() {
        XCTAssertEqual(lines("Quarterly_Report_draft_v2_final.pdf", 5), ["Quarterly_", "Report_dra", "ft_v2_fina", "l.pdf"])
        XCTAssertEqual(lines("The quick brown fox jumps.txt", 5), ["The quick", "brown fox", "jumps.txt"])
        // Past five lines, the fifth gets the same cut.
        let long = "The quick brown fox jumps over the lazy dog and runs away into the woods.txt"
        let five = lines(long, 5)
        XCTAssertEqual(five.count, 5)
        XCTAssertEqual(five.prefix(4), ["The quick", "brown fox", "jumps over", "the lazy"])
        XCTAssertTrue(five[4].contains("…") && five[4].hasSuffix(".txt"), five[4])
    }

    func testALineBreakInANameShowsAsASpace() {
        XCTAssertEqual(lines("line\nbreak in the name.txt"), ["line break", "in th….txt"])
        XCTAssertEqual(lines("a\r\nb"), ["a b"])
    }

    func testNamesThatAreJustAnExtension() {
        XCTAssertEqual(lines(".pdf"), [".pdf"])
        XCTAssertEqual(lines(".gitignore"), [".gitignore"])
        XCTAssertEqual(GridNameShortener.extensionLength(of: ".gitignore"), 0)
        // A long one is cut like any other name, with no extension to keep.
        XCTAssertEqual(lines(".gitignore_but_much_longer_than_a_line"), [".gitignore", "_but_…line"])
        XCTAssertEqual(lines("."), ["."])
        XCTAssertEqual(lines(""), [""])
    }

    func testExtensions() {
        XCTAssertEqual(GridNameShortener.extensionLength(of: "report.pdf"), 4)
        XCTAssertEqual(GridNameShortener.extensionLength(of: "archive.tar.gz"), 3)
        XCTAssertEqual(GridNameShortener.extensionLength(of: "Party.numbers"), 8)
        XCTAssertEqual(GridNameShortener.extensionLength(of: "Version 2.0 notes"), 0, "an ending with a space is no extension")
        XCTAssertEqual(GridNameShortener.extensionLength(of: "file."), 0)
        XCTAssertEqual(GridNameShortener.extensionLength(of: "no extension"), 0)
        XCTAssertEqual(GridNameShortener.extensionLength(of: "a.thisendingistoolongtobeone"), 0)
    }

    /// The extension stays whole even when it needs more than half the line, and the start gets what's left.
    func testTheExtensionIsAlwaysKept() {
        let cut = lines("Quarterly_Report_draft_v2_final_reviewed.numbers")
        XCTAssertEqual(cut, ["Quarterly_", "R….numbers"])
        // Only when the extension can't fit beside the ellipsis does the end keep as much of it as fits.
        let narrow = GridNameShortener.lines(for: "Quarterly report.download", width: GridNameShortener.measure("x", mono) * 6.5,
                                             font: mono, maxLines: 2).lines
        XCTAssertEqual(narrow, ["Quarte", "…nload"])
    }

    // MARK: The rule at every size

    private static let names = [
        "notes.txt", "Two words.md", "Annual budget review.xlsx",
        "Quarterly_Report_draft_v2_final_reviewed_by_finance.pdf",
        "The quick brown fox jumps over the lazy dog and keeps on running far away.txt",
        "Supercalifragilisticexpialidocious_without_any_spaces_at_all_in_it.docx",
        "日本語のとても長いファイル名のテストです。これは表示の確認用.txt",
        "🎉 Party planning 2026 — guests, food, music and more 🎶.numbers",
        "👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦.png",
        "Cafe\u{301} re\u{301}sume\u{301} with combining marks, many of them, again and again.txt",
        "مستند طويل جدا للاختبار في عرض الشبكة مع اسم طويل.pdf",
        ".gitignore", ".pdf", ".a_very_long_dotfile_name_that_goes_on_and_on_forever",
        String(repeating: "Long name part ", count: 15) + "end.md",
        String(repeating: "x", count: 240) + ".txt",
        "Screen Recording 2026-11-10 at 10.23.45 AM.mov",
        "한국어 파일 이름이 아주 길어서 두 줄에 다 들어가지 않습니다.hwp",
        "Ελληνικά 한국어.photoslibrary",
        "Quarterly Report the.txt",
        "My vacation photos from Hawaii",
        "of_русский_x_Résumé_(1)_k_náme_مستند_русский",
        "x_Report_طويل_Screenshot_WWWWWWWW_Quarterly"
    ]

    /// Lines are whole characters of the name, in order: whole lines first, then on a cut line the start of what's
    /// left, the ellipsis and the end of the name.
    private func checkShape(_ result: GridNameLines, name: String, font: NSFont, width: CGFloat, maxLines: Int,
                            file: StaticString = #filePath, line: UInt = #line) {
        let shown = String(name.map { $0.isNewline ? " " : $0 })
        let context = "“\(name)” at \(width) points in \(font.pointSize) point type: \(result.lines)"
        XCTAssertLessThanOrEqual(result.lines.count, maxLines, context, file: file, line: line)
        XCTAssertGreaterThan(result.lines.count, 0, context, file: file, line: line)
        let squeezed = { (text: String) in text.filter { !$0.isWhitespace } }
        if !result.isShortened {
            XCTAssertEqual(squeezed(result.lines.joined()), squeezed(shown), "a name that fits is shown whole: \(context)", file: file, line: line)
            return
        }
        XCTAssertEqual(result.lines.count, maxLines, "only a name that needs more lines is cut: \(context)", file: file, line: line)
        let whole = squeezed(result.lines.dropLast().joined())
        XCTAssertTrue(squeezed(shown).hasPrefix(whole), "the first lines are the start of the name: \(context)", file: file, line: line)
        let last = result.lines[result.lines.count - 1]
        let parts = last.components(separatedBy: GridNameShortener.ellipsis)
        XCTAssertEqual(parts.count, 2, "one cut, on the last line: \(context)", file: file, line: line)
        guard parts.count == 2 else { return }
        XCTAssertTrue(squeezed(shown).dropFirst(whole.count).hasPrefix(squeezed(parts[0])), "the cut line starts where the others end: \(context)",
                      file: file, line: line)
        XCTAssertTrue(squeezed(shown).hasSuffix(squeezed(parts[1])), "the cut line ends with the end of the name: \(context)", file: file, line: line)
        let ending = GridNameShortener.extensionLength(of: shown)
        if ending > 0, GridNameShortener.measure(GridNameShortener.ellipsis + String(shown.suffix(ending)), font) <= width {
            XCTAssertTrue(last.hasSuffix(String(shown.suffix(ending))), "the extension is kept: \(context)", file: file, line: line)
        }
        XCTAssertLessThanOrEqual(GridNameShortener.measure(last, font), width + 0.01, "the cut line fits: \(context)", file: file, line: line)
    }

    /// From 80% to 170% text and every icon size, light names and heavy ones, the label is the judge: a name it fits
    /// in the lines allowed is shown whole, for it to wrap itself as before, on as many lines as it takes; a longer one
    /// is cut, on lines that each fit on one line of the real label, so it draws exactly those lines.
    func testEveryTextSizeAndIconSize() {
        let label = GridNameLabel(wrappingLabelWithString: "")
        label.alignment = .center
        for percent in stride(from: 80, through: 170, by: 10) {
            let font = NSFont.systemFont(ofSize: CGFloat(percent) / 100 * 14)
            let lineHeight = GridNameMetrics.lineHeight(for: font)
            label.font = font
            for icon in stride(from: 48, through: 128, by: 16) {
                let metrics = GridItemMetrics(iconSize: CGFloat(icon), lineHeight: lineHeight)
                func linesDrawn(_ words: String) -> Int {
                    label.stringValue = words
                    let height = label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: metrics.labelFrameWidth, height: 10_000)).height ?? 0
                    return Int((height / lineHeight).rounded())
                }
                for name in Self.names {
                    let shown = String(name.map { $0.isNewline ? " " : $0 })
                    let natural = linesDrawn(shown)
                    for maxLines in [GridItemMetrics.linesShown, GridItemMetrics.linesSelected] {
                        let result = GridNameShortener.lines(for: name, width: metrics.textWidth, font: font, maxLines: maxLines)
                        let context = "\(percent)% text, \(icon) icons, “\(name)” in \(maxLines): \(result.lines), the label takes \(natural)"
                        checkShape(result, name: name, font: font, width: metrics.textWidth, maxLines: maxLines)
                        XCTAssertEqual(result.isShortened, natural > maxLines, context)
                        if !result.isShortened {
                            XCTAssertEqual(result.text, shown, "a name that fits is the label's to wrap: \(context)")
                            XCTAssertEqual(result.lines.count, natural, context)
                        }
                        XCTAssertEqual(linesDrawn(result.text), result.lines.count, "drawn on other lines than worked out: \(context)")
                    }
                }
            }
        }
    }

    /// The lines end where the label itself ends them, not where CoreText would: a Korean word, which the label keeps
    /// whole, isn't split between two lines, and that holds on the lines kept before a cut too.
    func testAKoreanWordIsNeverSplit() {
        let font = NSFont.systemFont(ofSize: 14)
        let name = "Ελληνικά 한국어.photoslibrary"
        // Room for “Ελληνικά 한국” but not for “Ελληνικά 한국어”: CoreText would break inside the Korean word.
        let width = GridNameShortener.measure("Ελληνικά 한국", font) + 0.5
        XCTAssertGreaterThan(GridNameShortener.measure("Ελληνικά 한국어", font), width)
        let whole = GridNameShortener.lines(for: name, width: width, font: font, maxLines: 5)
        XCTAssertFalse(whole.isShortened)
        XCTAssertEqual(whole.lines.first, "Ελληνικά", "\(whole.lines)")
        XCTAssertTrue(whole.lines[1].hasPrefix("한국어"), "\(whole.lines)")
        // In two lines the Korean word goes to the cut line, which keeps the end of the name.
        let cutShort = GridNameShortener.lines(for: name, width: width, font: font, maxLines: 2)
        XCTAssertTrue(cutShort.isShortened)
        XCTAssertEqual(cutShort.lines.first, "Ελληνικά", "\(cutShort.lines)")
        XCTAssertTrue(cutShort.lines[1].hasSuffix("library"), "\(cutShort.lines)")
        let long = "한국어 파일 이름이 아주 길어서 두 줄에 다 들어가지 않습니다.hwp"
        let cut = GridNameShortener.lines(for: long, width: 100, font: font, maxLines: 2)
        XCTAssertTrue(cut.isShortened)
        let words = long.split(separator: " ").map(String.init)
        XCTAssertTrue(words.contains { $0 == cut.lines[0] || cut.lines[0].hasSuffix($0) }, "the first line ends inside a word: \(cut.lines)")
        XCTAssertTrue(cut.lines[1].hasSuffix(".hwp"), "\(cut.lines)")
    }

    /// The lines never split a character made of several, such as an emoji family or a letter with its accent.
    func testCharactersAreNeverSplit() {
        let font = NSFont.systemFont(ofSize: 14)
        let family = "👨‍👩‍👧‍👦"
        let name = String(repeating: family, count: 12) + ".png"
        let result = GridNameShortener.lines(for: name, width: 100, font: font, maxLines: 2)
        XCTAssertTrue(result.isShortened)
        for line in result.lines {
            for character in line where character != "…" && !".png".contains(character) {
                XCTAssertEqual(character, Character(family), "a family emoji was split: \(result.lines)")
            }
        }
        let accents = String(repeating: "e\u{301}", count: 60)
        let cut = GridNameShortener.lines(for: accents, width: 100, font: font, maxLines: 2)
        for line in cut.lines { XCTAssertTrue(line.allSatisfy { $0 == "e\u{301}" || $0 == "…" }, "\(cut.lines)") }
    }

    /// The cut line is as full as it can be: one more character of the start or of the end wouldn't fit.
    func testTheCutLineIsFull() {
        let font = NSFont.systemFont(ofSize: 14)
        let width: CGFloat = 136
        var checked = 0
        for name in Self.names {
            let result = GridNameShortener.lines(for: name, width: width, font: font, maxLines: 2)
            guard result.isShortened, let first = result.lines.first, let last = result.lines.last else { continue }
            let parts = last.components(separatedBy: GridNameShortener.ellipsis)
            let shown = String(name.map { $0.isNewline ? " " : $0 })
            guard parts.count == 2, shown.hasPrefix(first) else { XCTFail("“\(name)”: \(result.lines)"); continue }
            // What was left for the last line: the name after the first line.
            let rest = Array(shown.dropFirst(first.count).drop { $0.isWhitespace })
            let head = parts[0].count, tail = parts[1].count
            // The next letter of the start, and the letter before the end, past any spaces at the cut.
            if let next = rest.indices.dropFirst(head).first(where: { !rest[$0].isWhitespace }), next < rest.count - tail {
                let longer = String(rest[...next]) + GridNameShortener.ellipsis + parts[1]
                XCTAssertGreaterThan(GridNameShortener.measure(longer, font), width, "“\(name)”: “\(last)” had room for more of the start")
            }
            if let previous = rest.indices.prefix(rest.count - tail).last(where: { !rest[$0].isWhitespace }), previous >= head {
                let longer = parts[0] + GridNameShortener.ellipsis + String(rest[previous...])
                XCTAssertGreaterThan(GridNameShortener.measure(longer, font), width, "“\(name)”: “\(last)” had room for more of the end")
            }
            checked += 1
        }
        XCTAssertGreaterThan(checked, 8)
    }

    /// The label wraps a line its text width can't hold: it keeps `textInset` points of its width clear of the text,
    /// which is what the lines leave out. A line that wide stays on one line, and one a little wider wraps.
    func testTheLabelInsetIsAppKits() {
        let label = GridNameLabel(wrappingLabelWithString: "")
        label.alignment = .center
        for size in [11.2, 14, 16.8, 23.8] as [CGFloat] {
            let font = NSFont.systemFont(ofSize: size)
            label.font = font
            for words in ["Quarterly_Report", "Supercalifragilis", "日本語のファイル", "abc def"] {
                label.stringValue = words
                let width = GridNameShortener.measure(words, font)
                func lines(_ labelWidth: CGFloat) -> CGFloat {
                    (label.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: labelWidth, height: 10_000)).height ?? 0)
                        / GridNameMetrics.lineHeight(for: font)
                }
                XCTAssertEqual(lines(width + GridNameLabel.textInset), 1, accuracy: 0.01, "“\(words)” at \(size) points wrapped")
                XCTAssertEqual(lines(width + GridNameLabel.textInset - 0.5), 2, accuracy: 0.01, "“\(words)” at \(size) points had more room")
            }
        }
    }

    // MARK: Cache and speed

    func testEachNameIsWorkedOutOnce() {
        let cache = GridNameCache()
        let font = NSFont.systemFont(ofSize: 14)
        let first = cache.lines(for: "Quarterly_Report_draft_v2_final.pdf", width: 136, font: font, maxLines: 2)
        let again = cache.lines(for: "Quarterly_Report_draft_v2_final.pdf", width: 136, font: font, maxLines: 2)
        XCTAssertEqual(first, again)
        XCTAssertEqual(cache.computed, 1)
        // A new width, font or line limit is a new answer.
        _ = cache.lines(for: "Quarterly_Report_draft_v2_final.pdf", width: 120, font: font, maxLines: 2)
        _ = cache.lines(for: "Quarterly_Report_draft_v2_final.pdf", width: 136, font: .systemFont(ofSize: 15.4), maxLines: 2)
        _ = cache.lines(for: "Quarterly_Report_draft_v2_final.pdf", width: 136, font: font, maxLines: 5)
        XCTAssertEqual(cache.computed, 4)
        // A full cache starts again rather than growing for ever.
        let small = GridNameCache(capacity: 2)
        for index in 0..<5 { _ = small.lines(for: "name \(index)", width: 136, font: font, maxLines: 2) }
        _ = small.lines(for: "name 4", width: 136, font: font, maxLines: 2)
        XCTAssertEqual(small.computed, 5)
    }

    /// Thousands of long names, each worked out once, then scrolled past again for free.
    func testThousandsOfNamesStayFast() {
        let cache = GridNameCache()
        let font = NSFont.systemFont(ofSize: 14)
        let names = (0..<3_000).map { "Quarterly report \($0) for the finance team, reviewed and final version \($0 * 7).pdf" }
        let start = Date()
        for name in names { XCTAssertTrue(cache.lines(for: name, width: 136, font: font, maxLines: 2).isShortened) }
        let firstPass = Date().timeIntervalSince(start)
        let again = Date()
        for name in names { _ = cache.lines(for: name, width: 136, font: font, maxLines: 2) }
        let secondPass = Date().timeIntervalSince(again)
        XCTAssertEqual(cache.computed, names.count, "each name is worked out once")
        XCTAssertLessThan(firstPass, 6, "3,000 long names took \(firstPass) seconds")
        XCTAssertLessThan(secondPass, firstPass / 5, "looking names up again took \(secondPass) seconds, against \(firstPass)")
    }
}
#endif
