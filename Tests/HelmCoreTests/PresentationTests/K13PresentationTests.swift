// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore

final class K13PresentationTests: XCTestCase {
    /// F-029: tag bytes preserve Unicode, duplicates, and unknown colors.
    func testTagUnicodeRawRoundTrip() throws {
        let tags = TagSet(tags: [FinderTag(rawValue: "cafe\u{301}\n99"), FinderTag(rawValue: "مرحبا😀\n6"), FinderTag(rawValue: "cafe\u{301}\n99")])
        let decoded = try FinderTagCodec.decode(FinderTagCodec.encode(tags))
        XCTAssertEqual(decoded, tags)
        XCTAssertEqual(decoded.tags.map { Array($0.rawValue.utf8) }, tags.tags.map { Array($0.rawValue.utf8) })
    }
    /// F-029: malformed color suffixes remain opaque.
    func testTagLastNewlineAndOverflow() throws {
        let tag = FinderTag(rawValue: "a\nb\n999999999999999999999999")
        XCTAssertEqual(tag.name, "a\nb")
        XCTAssertNil(tag.colorIndex)
        XCTAssertNil(tag.color)
    }
    /// F-029: malformed tag metadata cannot be silently replaced.
    func testTagWrongPlistType() throws {
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["tag": "red"], format: .binary, options: 0)
        XCTAssertThrowsError(try FinderTagCodec.decode(bytes))
    }
    /// F-038, B-011: duplicate tags never duplicate rows within a group.
    func testTagGroupingDeduplicatesMembership() throws {
        let entry = FileEntry(url: URL(fileURLWithPath: "/a"))
        let tag = FinderTag(name: "x", colorIndex: 1)
        let groups = FileGrouping.groups([entry], by: .tag, tags: [entry.id: TagSet(tags: [tag, tag])])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.items, [entry])
    }
    /// F-040, B-066: metadata bucket edges are exact.
    func testSizeBucketBoundaries() throws {
        let cases: [(Int64, FileSizeBucket)] = [(Int64.min, .unknown), (0, .empty), (999_999, .underMegabyte), (1_000_000, .underGigabyte), (999_999_999, .underGigabyte), (1_000_000_000, .gigabyteOrMore), (Int64.max, .gigabyteOrMore)]
        for (size, expected) in cases { XCTAssertEqual(FileGrouping.sizeBucket(size), expected) }
    }
    /// F-040: empty input has no phantom sections.
    func testEmptyGrouping() throws {
        for grouping in [GroupBy.none, .kind, .size, .dateModified, .tag] { XCTAssertTrue(FileGrouping.groups([], by: grouping).isEmpty) }
    }
    /// F-065: invalid floating point values use defaults.
    func testViewOptionsNonFinite() throws {
        let options = ViewOptions(iconSize: .infinity, showColumns: [], textSize: .nan)
        XCTAssertEqual(options.iconSize, 96)
        XCTAssertEqual(options.textSize, 12)
        XCTAssertEqual(options.showColumns, [.name])
    }
    /// F-065: failed decoding is transactional.
    func testFutureRestorePreservesCache() throws {
        var store = ViewOptionsStore()
        store.set(ViewOptions(viewMode: .list), for: .recent)
        XCTAssertThrowsError(try store.restore(Data(#"{"version":99}"#.utf8), for: .recent))
        XCTAssertEqual(store.options(for: .recent).viewMode, .list)
    }
    /// F-065: disabled cache retains no entries.
    func testZeroCapacityStore() throws {
        var store = ViewOptionsStore(capacity: Int.min)
        store.set(ViewOptions(viewMode: .list), for: .recent)
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(store.options(for: .recent), ViewOptions())
    }
    /// F-065: a cache miss cannot consume an LRU slot.
    func testMissingReadDoesNotEvict() throws {
        var store = ViewOptionsStore(capacity: 1)
        store.set(ViewOptions(viewMode: .list), for: .recent)
        _ = store.options(for: .trash)
        XCTAssertEqual(store.locationsLeastRecentlyUsedFirst, [.recent])
    }
    /// F-064, B-011: selection count is bounded by visible count.
    func testStatusExtremeCounts() throws {
        let value = StatusPresentation(itemCount: 1, selectedCount: Int.max, selectedBytes: -1, freeBytes: -1)
        XCTAssertEqual(StatusText.format(value), "1 item  •  1 selected")
        XCTAssertEqual(StatusPresentation(itemCount: Int.min, selectedCount: Int.max).selectedCount, 0)
    }
    /// F-064, B-017: denial cannot look like a successful listing.
    func testDeniedStatusSuppressesStaleCounts() throws {
        XCTAssertEqual(StatusText.format(StatusPresentation(itemCount: 50, selectedCount: 10, freeBytes: 100, activity: .denied)), "Permission denied")
    }
    /// F-050, B-066: unknown sizes are distinct from zero.
    func testUnknownSizeIsNotEmpty() throws {
        let entries = [FileEntry(url: URL(fileURLWithPath: "/a"), size: -1), FileEntry(url: URL(fileURLWithPath: "/b"), size: 0)]
        let model = PropertiesModel(entries: entries)
        XCTAssertEqual(model.totalSize, 0)
        XCTAssertTrue(model.hasUnknownSize)
        XCTAssertTrue(model.hasMixedSizes)
        XCTAssertFalse(model.sizeOverflowed)
    }
    /// F-038, B-010: grouping retains stable item identity at scale.
    func testLargeGroupingPreservesOrder() throws {
        let entries = (0..<10_000).map { FileEntry(url: URL(fileURLWithPath: "/r/\($0)"), size: 1) }
        let groups = FileGrouping.groups(entries, by: .size)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.items.map(\.id), entries.map(\.id))
    }
}
