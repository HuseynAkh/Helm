// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

private struct T3Clock: HelmClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_700_000_000) }
}

/// F-064/B-061: locale-specific numeric speech, with the documented English phrase policy.
final class T3AccessibilityTests: XCTestCase {
    private func format(_ locale: String) -> AccessibilityFormatting {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        return AccessibilityFormatting(locale: Locale(identifier: locale), calendar: calendar, clock: T3Clock())
    }
    private func checkCounts(_ locale: String, digits: String) {
        let f = format(locale)
        let expected = Array(digits)
        for n in 0...9 { XCTAssertEqual(f.count(n), String(expected[n])) }
        XCTAssertEqual(f.count(Int.min), String(expected[0]))
        let huge = f.count(Int.max).filter { $0.wholeNumberValue != nil }.compactMap { $0.wholeNumberValue }.map(String.init).joined()
        XCTAssertEqual(huge, String(Int.max))
    }
    private func checkPlural(_ locale: String) {
        let f = format(locale)
        for n in [-1, 0, 1, 2, 3, 11, 21, 101, Int.max] {
            let count = max(0, n)
            let suffix = count == 1 ? "item" : "items"
            XCTAssertEqual(NavigationAnnouncement.describe(folderName: "資料 العربية", itemCount: n, state: .loaded, formatting: f),
                           "Entered 資料 العربية, \(f.count(count)) \(suffix)")
        }
    }
    private func checkSelection(_ locale: String) {
        let f = format(locale)
        for (selected, total, expected) in [(Int.max, 2, 2), (-1, 3, 0), (1, -1, 0), (1, Int.max, 1)] {
            let result = SelectionAnnouncement.describe(selectedCount: selected, itemCount: total, selectedBytes: 1, formatting: f)
            XCTAssertEqual(result, "\(f.count(expected)) of \(f.count(max(0, total))) selected" + (expected > 0 ? ", \(f.count(1)) byte" : ""))
        }
    }
    private func checkSizes(_ locale: String) {
        let f = format(locale)
        for (n, unit): (Int64, String) in [(0,"bytes"),(1,"byte"),(2,"bytes"),(999,"bytes"),(1000,"KB"),(999_999,"MB"),(Int64.max,"EB")] {
            XCTAssertTrue(f.bytes(n)?.hasSuffix(" " + unit) == true)
        }
        XCTAssertEqual(f.bytes(999_999), f.count(1) + " MB")
        XCTAssertNil(f.bytes(Int64.min))
        XCTAssertNil(f.bytes(-1))
    }
    private func checkRows(_ locale: String) {
        let f = format(locale)
        let name = "تقرير-資料-été.txt"
        for (kind, sized): (FileEntryKind, Bool) in [(.regular,true),(.directory,false),(.package,false),(.symlinkToDirectory,false),(.symlinkToFile,true),(.danglingSymlink,true),(.alias,true),(.other,true)] {
            let entry = FileEntry(url: URL(fileURLWithPath: "/" + name), kind: kind, size: 1234)
            for verbosity in [RowDescription.Verbosity.standard, .detailed] {
                let speech = RowDescription(verbosity: verbosity).label(for: entry, selected: true, formatting: f)
                XCTAssertTrue(speech.hasPrefix(name + ", "))
                XCTAssertTrue(speech.contains(", selected"))
                if let size = f.bytes(1234) { XCTAssertEqual(speech.contains(size), sized) }
                XCTAssertFalse(speech.contains("modified"))
            }
        }
    }
    private func checkMilestones(_ locale: String) {
        let f = format(locale)
        var value = OperationAnnouncement(operationName: "نسخ", milestonePercent: 7, minimumInterval: 0)
        XCTAssertEqual(value.announcement(for: .started, formatting: f), "نسخ started")
        XCTAssertNil(value.announcement(for: .progress(.nan), formatting: f))
        XCTAssertEqual(value.announcement(for: .progress(0.29), formatting: f), "نسخ, \(f.count(28)) percent")
        XCTAssertNil(value.announcement(for: .progress(0.1), formatting: f))
        XCTAssertEqual(value.announcement(for: .progress(2), formatting: f), "نسخ, \(f.count(100)) percent")
        XCTAssertEqual(value.announcement(for: .cancelled, formatting: f), "نسخ cancelled")
        XCTAssertNil(value.announcement(for: .completed, formatting: f))
    }
    func testfr_FR_Counts() { checkCounts("fr_FR", digits: "0123456789") }
    func testfr_FR_Plural() { checkPlural("fr_FR") }
    func testfr_FR_Selection() { checkSelection("fr_FR") }
    func testfr_FR_Sizes() { checkSizes("fr_FR") }
    func testfr_FR_Rows() { checkRows("fr_FR") }
    func testfr_FR_Milestones() { checkMilestones("fr_FR") }
    func testar_Counts() { checkCounts("ar-EG", digits: "٠١٢٣٤٥٦٧٨٩") }
    func testar_Plural() { checkPlural("ar-EG") }
    func testar_Selection() { checkSelection("ar-EG") }
    func testar_Sizes() { checkSizes("ar-EG") }
    func testar_Rows() { checkRows("ar-EG") }
    func testar_Milestones() { checkMilestones("ar-EG") }
    func testde_Counts() { checkCounts("de", digits: "0123456789") }
    func testde_Plural() { checkPlural("de") }
    func testde_Selection() { checkSelection("de") }
    func testde_Sizes() { checkSizes("de") }
    func testde_Rows() { checkRows("de") }
    func testde_Milestones() { checkMilestones("de") }
    func testja_Counts() { checkCounts("ja", digits: "0123456789") }
    func testja_Plural() { checkPlural("ja") }
    func testja_Selection() { checkSelection("ja") }
    func testja_Sizes() { checkSizes("ja") }
    func testja_Rows() { checkRows("ja") }
    func testja_Milestones() { checkMilestones("ja") }
    func testIdentifiersPreserveRTLAndNormalizationDistinctions() {
        let names = ["عربي", "資料", "é", "e\u{301}", ".item.", "", "a/b", "a.b"]
        let identifiers = names.map { AccessibilityIdentifier.control($0, in: .inspector, scope: "نافذة") }
        XCTAssertEqual(Set(identifiers).count, names.count)
        XCTAssertEqual(identifiers, names.map { AccessibilityIdentifier.control($0, in: .inspector, scope: "نافذة") })
        XCTAssertTrue(identifiers.allSatisfy { $0.utf8.allSatisfy { $0 < 128 } })
    }
}
