// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

private struct GroupingClock: HelmClock {
    let date: Date
    func now() -> Date { date }
}

final class PresentationGroupingTests: XCTestCase {
    func testDateBoundariesAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Toronto"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 0, minute: 1)))
        let cases: [(Int, ModifiedDateBucket)] = [(-1, .future), (0, .today), (1, .yesterday),
            (2, .previous7Days), (7, .previous7Days), (8, .previous30Days), (30, .previous30Days), (31, .earlier)]
        for (age, expected) in cases {
            let date = try XCTUnwrap(calendar.date(byAdding: .day, value: -age, to: now))
            XCTAssertEqual(FileGrouping.dateBucket(date, now: now, calendar: calendar), expected)
        }
        XCTAssertEqual(FileGrouping.dateBucket(.distantPast, now: now, calendar: calendar), .unknown)
        let yesterday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 23, minute: 59)))
        XCTAssertEqual(FileGrouping.dateBucket(yesterday, now: now, calendar: calendar), .yesterday)
        let entries = [entry("y", date: yesterday), entry("a", date: now), entry("b", date: now)]
        let groups = FileGrouping.groups(entries, by: .dateModified, clock: GroupingClock(date: now), calendar: calendar)
        XCTAssertEqual(groups.map(\.key), [.date(.today), .date(.yesterday)])
        XCTAssertEqual(groups[0].items.map(\.name), ["a", "b"])
    }
    func testSizeBuckets() {
        let cases: [(Int64, FileSizeBucket)] = [(-1, .unknown), (0, .empty), (1, .underMegabyte),
            (999_999, .underMegabyte), (1_000_000, .underGigabyte), (999_999_999, .underGigabyte),
            (1_000_000_000, .gigabyteOrMore), (.max, .gigabyteOrMore)]
        for (size, bucket) in cases { XCTAssertEqual(FileGrouping.sizeBucket(size), bucket) }
        let groups = FileGrouping.groups([entry("b", size: .max), entry("a", size: 0)], by: .size)
        XCTAssertEqual(groups.map(\.key), [.size(.empty), .size(.gigabyteOrMore)])
    }
    func testKindTagsAndStableMembership() {
        let entries = [entry("a"), entry("b", kind: .directory), entry("c")]
        XCTAssertEqual(FileGrouping.groups(entries, by: .kind).map { $0.items.map(\.name) }, [["a", "c"], ["b"]])
        XCTAssertEqual(FileGrouping.groups(entries, by: .none).first?.items, entries)
        XCTAssertTrue(FileGrouping.groups([], by: .none).isEmpty)
        let red = FinderTag(name: "Red", colorIndex: 6), unknown = FinderTag(rawValue: "Unknown\n90")
        let tags = [entries[0].id: TagSet(tags: [red, unknown, red]), entries[2].id: TagSet(tags: [red])]
        let groups = FileGrouping.groups(entries, by: .tag, tags: tags)
        XCTAssertEqual(groups.map(\.key), [.tag(red), .tag(unknown), .untagged])
        XCTAssertEqual(groups[0].items.map(\.name), ["a", "c"])
        XCTAssertEqual(groups[1].items.count, 1)
    }
    private func entry(_ name: String, kind: FileEntryKind = .regular, size: Int64 = 0, date: Date = .distantPast) -> FileEntry {
        FileEntry(url: URL(fileURLWithPath: "/\(name)"), kind: kind, size: size, modificationDate: date)
    }
}
