// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

private struct TestStatusBytes: StatusByteFormatting {
    func string(from bytes: Int64) -> String { "\(bytes)B" }
}

final class PresentationStatusAndTagsTests: XCTestCase {
    func testStatusTable() {
        let cases: [(StatusPresentation, String)] = [
            (.init(itemCount: 0), "0 items"), (.init(itemCount: 1), "1 item"),
            (.init(itemCount: 4, selectedCount: 2, selectedBytes: 42, freeBytes: 100), "4 items  •  2 selected  •  42B  •  100B free"),
            (.init(itemCount: -1, selectedCount: 5, selectedBytes: 10, freeBytes: -1), "0 items"),
            (.init(itemCount: 1, selectedCount: 1, selectedBytes: .max), "1 item  •  1 selected  •  9223372036854775807B"),
            (.init(itemCount: 0, activity: .searching), "Searching…  •  0 items"),
            (.init(itemCount: 3, activity: .gathering), "Gathering items…  •  3 items"),
            (.init(itemCount: 0, freeBytes: 100, activity: .denied), "Permission denied")
        ]
        for (input, expected) in cases { XCTAssertEqual(StatusText.format(input, bytes: TestStatusBytes()), expected) }
        XCTAssertEqual(StatusText.format(.init(itemCount: 3, selectedCount: 1), selectionWording: .fraction), "1 of 3 selected")
        XCTAssertFalse(LocalizedStatusByteFormatter().string(from: .max).isEmpty)
    }
    func testTagCodecPreservesUnknownEntries() throws {
        let raw = ["Red\n6", "Future\n99", "No suffix", "Odd\nwat", "Nested\nName\n-1", "", "Red\n6"]
        let set = TagSet(tags: raw.map { FinderTag(rawValue: $0) })
        let data = try FinderTagCodec.encode(set)
        XCTAssertEqual(String(data: data.prefix(8), encoding: .ascii), "bplist00")
        XCTAssertEqual(try FinderTagCodec.decode(data), set)
        XCTAssertEqual(set.tags[1].colorIndex, 99)
        XCTAssertNil(set.tags[1].color)
        XCTAssertNil(set.tags[2].colorIndex)
        XCTAssertEqual(set.tags[4].name, "Nested\nName")
        XCTAssertEqual(FinderTagColor.allCases.map(\.rawValue), Array(0...7))
        XCTAssertEqual(FinderTag(name: "Red", colorIndex: 6).color, .red)
        XCTAssertThrowsError(try FinderTagCodec.decode(Data()))
        let invalid = try PropertyListSerialization.data(fromPropertyList: [1, 2], format: .binary, options: 0)
        XCTAssertThrowsError(try FinderTagCodec.decode(invalid))
    }
    func testSingleTagEditsPreserveOthers() {
        let a = FinderTag(name: "A", colorIndex: 1)
        let b = FinderTag(rawValue: "Unknown\n999")
        var tags = TagSet(tags: [a, b])
        tags.add(a); XCTAssertEqual(tags.tags, [a, b])
        tags.remove(a); XCTAssertEqual(tags.tags, [b])
        tags.remove(a); XCTAssertEqual(tags.tags, [b])
    }
    func testPartialTagFailure() async throws {
        let a = ItemID(rawValue: "/a"), b = ItemID(rawValue: "/b")
        let old = FinderTag(rawValue: "Old\n99"), new = FinderTag(name: "New", colorIndex: 4)
        let storage = InMemoryTagStorage(values: [a: TagSet(tags: [old])], deniedItems: [b])
        let result = await TagEditResult.apply(.add(new), to: [a, b, a], storage: storage)
        XCTAssertEqual(result.succeeded, [a]); XCTAssertEqual(result.failures.map(\.item), [b])
        XCTAssertTrue(result.isPartialFailure)
        let tags = try await storage.tags(for: a)
        XCTAssertEqual(tags.tags, [old, new])
        try await storage.apply(.remove(new), to: a)
        let remaining = try await storage.tags(for: a)
        XCTAssertEqual(remaining.tags, [old])
        let empty = await TagEditResult.apply(.add(new), to: [], storage: storage)
        XCTAssertFalse(empty.isPartialFailure)
        let failed = await TagEditResult.apply(.add(new), to: [b], storage: storage)
        XCTAssertFalse(failed.isPartialFailure)
    }
}
