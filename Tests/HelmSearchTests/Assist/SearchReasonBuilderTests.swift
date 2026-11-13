import XCTest
import HelmCore
@testable import HelmSearch

/// Reason lines and the "read as" line: facts Helm can back, two at most, in plain escaped words, never a path.
final class SearchReasonBuilderTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/home/helmuser", isDirectory: true)
    private var root: URL { home.appendingPathComponent("Downloads", isDirectory: true) }
    private let locale = Locale(identifier: "en_US")
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
    private var thisYear: Int { calendar.component(.year, from: Date()) }

    private func entry(_ path: String, size: Int64 = 2_400_000_000, modified: Date? = nil, kind: FileEntryKind = .regular) -> FileEntry {
        FileEntry(url: root.appendingPathComponent(path), kind: kind, size: size, modificationDate: modified ?? day(2025, 3, 14))
    }

    private func reason(_ codes: [SearchReasonCode], _ entry: FileEntry, _ query: AISearchQuery?) -> SearchReason? {
        SearchReasonBuilder.reason(codes: codes, entry: entry, query: query, scopeRoot: root, calendar: calendar, locale: locale)
    }

    func testEachCodesWords() {
        let query = AISearchQuery(nameAny: ["receipt", "invoice"], contentAll: ["plumber"], folderAny: ["receipt"], kinds: [.pdf],
                                  dateField: .modified)
        let item = entry("Receipts/Invoice-0042.pdf")
        XCTAssertEqual(reason([.name], item, query)?.line, "Name has “invoice”")
        XCTAssertEqual(reason([.content], item, query)?.line, "Mentions “plumber”")
        XCTAssertEqual(reason([.kind], item, query)?.line, "PDF")
        XCTAssertEqual(reason([.date], item, query)?.line, "Modified 14 Mar 2025")
        XCTAssertEqual(reason([.folder], item, query)?.line, "In Receipts")
        XCTAssertEqual(reason([.size], item, query)?.line, ByteCountFormatter.string(fromByteCount: 2_400_000_000, countStyle: .file))
    }

    func testTwoFactsAtMostInTheOrderGiven() {
        let query = AISearchQuery(nameAny: ["invoice"], kinds: [.pdf])
        let line = reason([.kind, .name, .size, .date], entry("invoice.pdf"), query)
        XCTAssertEqual(line?.codes, [.kind, .name])
        XCTAssertEqual(line?.line, "PDF · Name has “invoice”")
        XCTAssertEqual(reason([.name, .name, .name], entry("invoice.pdf"), query)?.codes, [.name], "a code counts once")
    }

    func testACodeHelmCantBackIsDropped() {
        let item = entry("Scan_0042.pdf")
        let nameOnly = AISearchQuery(nameAny: ["invoice"])
        XCTAssertNil(reason([.name], item, nameOnly), "the name holds none of the query's words")
        XCTAssertNil(reason([.content], item, nameOnly), "the query that found it didn't look inside files")
        XCTAssertNil(reason([.folder], item, nameOnly), "no folder words")
        XCTAssertNil(reason([.content, .name], item, nil), "no query at all")
        XCTAssertEqual(reason([.content, .kind], item, nameOnly)?.codes, [.kind], "what can be backed stays")
        XCTAssertNil(reason([.size], entry("Photos", kind: .directory), nameOnly), "a folder's size isn't known")
        XCTAssertNil(reason([.kind], entry("notes.weird"), nameOnly), "no kind for an unknown extension")
        let added = AISearchQuery(dateField: .added, dateFrom: day(2025, 1, 1))
        XCTAssertNil(reason([.date], item, added), "Helm doesn't know when a file was added")
        let elsewhere = AISearchQuery(folderAny: ["taxes"])
        XCTAssertNil(reason([.folder], entry("Receipts/scan.pdf"), elsewhere))
    }

    func testTheYearShowsOnlyWhenItIsntThisOne() {
        let item = entry("a.pdf", modified: day(thisYear, 3, 14))
        XCTAssertEqual(reason([.date], item, nil)?.line, "Modified 14 Mar")
        XCTAssertEqual(reason([.date], entry("b.pdf", modified: day(thisYear - 1, 11, 2)), nil)?.line, "Modified 2 Nov \(thisYear - 1)")
    }

    func testNoLineHoldsTheHomePathOrTheAccountName() {
        let query = AISearchQuery(nameAny: ["scan"], contentAll: ["plumber"], folderAny: ["receipts"], kinds: [.pdf], dateField: .modified)
        let item = entry("Receipts/scan.pdf")
        for first in SearchReasonCode.allCases {
            for second in SearchReasonCode.allCases {
                guard let line = reason([first, second], item, query)?.line else { continue }
                XCTAssertFalse(line.contains("/"), "no path in “\(line)”")
                XCTAssertFalse(line.contains("helmuser"), "no account name in “\(line)”")
            }
        }
        // With no folder searched, the folders above an item include the home folder's own name: a folder word can
        // only name a folder that holds it, and never as a path.
        let anywhere = SearchReasonBuilder.reason(codes: [.folder], entry: item, query: AISearchQuery(folderAny: ["receipts"]),
                                                  scopeRoot: nil, calendar: calendar, locale: locale)
        XCTAssertEqual(anywhere?.line, "In Receipts")
        let status = SearchReasonBuilder.readAs(count: 3, query: query, calendar: calendar, locale: locale)
        XCTAssertFalse(status.contains("/home") || status.contains("helmuser"))
    }

    func testWordsAndNamesAreEscaped() {
        let hidden = "inv\u{202E}oice"
        let query = AISearchQuery(nameAny: [hidden], folderAny: ["re"])
        let item = entry("Re\u{200B}ceipts/\(hidden).pdf")
        for codes in [[SearchReasonCode.name], [.folder]] {
            let line = try? XCTUnwrap(reason(codes, item, query)?.line)
            XCTAssertNotNil(line)
            XCTAssertFalse(line?.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0x200B } ?? true,
                           "no hidden character reaches a line")
            XCTAssertTrue(line.map(AgentTextEscaper.isClean) ?? false)
        }
        XCTAssertEqual(reason([.name], item, query)?.line, "Name has “\(AgentTextEscaper.escape(hidden))”")
        let readAs = SearchReasonBuilder.readAs(count: nil, query: AISearchQuery(nameAny: [hidden]), calendar: calendar, locale: locale)
        XCTAssertTrue(AgentTextEscaper.isClean(readAs))
    }

    func testReadAs() {
        let spring = AISearchQuery(nameAny: ["invoice"], kinds: [.pdf], dateField: .any,
                                   dateFrom: calendar.date(from: DateComponents(year: 2026, month: 3, day: 1)),
                                   dateTo: calendar.date(from: DateComponents(year: 2026, month: 6, day: 30, hour: 23, minute: 59)))
        XCTAssertEqual(SearchReasonBuilder.readAs(count: 12, query: spring, calendar: calendar, locale: locale),
                       "12 matches · PDF · “invoice” · Mar–Jun 2026")
        XCTAssertEqual(SearchReasonBuilder.readAs(count: nil, query: spring, calendar: calendar, locale: locale),
                       "PDF · “invoice” · Mar–Jun 2026", "a line of the list of queries has no count")
        XCTAssertEqual(SearchReasonBuilder.readAs(count: 1, query: AISearchQuery(nameAll: ["tax"]), calendar: calendar, locale: locale),
                       "1 match · “tax”")
        XCTAssertEqual(SearchReasonBuilder.readAs(count: 1240, query: AISearchQuery(contentAll: ["plumber"]), calendar: calendar,
                                                  locale: locale), "1,240 matches · Mentions “plumber”")
        var modified = spring; modified.dateField = .modified; modified.kinds = []; modified.nameAny = []
        XCTAssertEqual(SearchReasonBuilder.readAs(count: nil, query: modified, calendar: calendar, locale: locale), "Modified Mar–Jun 2026")
        let days = AISearchQuery(dateField: .created, dateFrom: day(2025, 3, 14), dateTo: day(2025, 4, 2))
        XCTAssertEqual(SearchReasonBuilder.readAs(count: nil, query: days, calendar: calendar, locale: locale), "Created 14 Mar–2 Apr 2025")
        let sizes = AISearchQuery(folderAny: ["Trips"], extensions: ["mov"], sizeMinBytes: 1_000_000)
        XCTAssertEqual(SearchReasonBuilder.readAs(count: nil, query: sizes, calendar: calendar, locale: locale),
                       ".mov · In Trips · ≥ " + ByteCountFormatter.string(fromByteCount: 1_000_000, countStyle: .file))
    }
}
