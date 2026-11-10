import Foundation
import XCTest
import HelmCore
import HelmTestKit

final class ModelTests: XCTestCase {
    func testIdentityAndLocation() throws {
        let id = ItemID(url: URL(fileURLWithPath: "/a/../b"))
        XCTAssertEqual(id.rawValue, "/b")
        XCTAssertEqual(ItemID(rawValue: "/b"), id)
        XCTAssertEqual(id.url.path, "/b")
        let locations: [Location] = [.directory(id.url), .recent, .trash]
        XCTAssertEqual(locations.map(\.kind), [.directory, .recent, .trash])
        XCTAssertEqual(locations[0].mutationTarget, id.url)
        XCTAssertNil(locations[1].mutationTarget)
        XCTAssertNil(locations[2].mutationTarget)
        XCTAssertEqual(try JSONDecoder().decode([Location].self, from: JSONEncoder().encode(locations)), locations)
        let uuid = UUID()
        XCTAssertEqual(TabID(rawValue: uuid).rawValue, uuid)
        XCTAssertEqual(OperationID(rawValue: uuid).rawValue, uuid)
        XCTAssertEqual(StepID(rawValue: uuid).rawValue, uuid)
        XCTAssertNotEqual(TabID(), TabID())
    }

    func testEntryMetadataAndKinds() throws {
        let fixture = TreeFixture()
        let entry = fixture.file("a", size: 4)
        XCTAssertEqual(entry.name, "a")
        XCTAssertEqual(entry.id.url, entry.url)
        XCTAssertEqual(entry.changeToken.size, 4)
        XCTAssertNotEqual(entry, fixture.file("a", size: 5))
        for kind in [FileEntryKind.regular, .directory, .package, .symlinkToDirectory, .symlinkToFile, .danglingSymlink, .alias, .other] {
            let item = FileEntry(url: entry.url, kind: kind, childCount: 3)
            XCTAssertEqual(item.isDirectoryLike, kind == .directory || kind == .symlinkToDirectory)
            XCTAssertEqual(item.changeToken.childCount, 3)
        }
        XCTAssertEqual(try JSONDecoder().decode(FileEntry.self, from: JSONEncoder().encode(entry)), entry)
        XCTAssertNotEqual(ChangeToken(modificationDate: .distantPast, size: 0, childCount: 1), ChangeToken(modificationDate: .distantPast, size: 0, childCount: 2))
        XCTAssertEqual(ViewMode.grid.rawValue, "grid")
        XCTAssertEqual(ViewMode.list.rawValue, "list")
        XCTAssertEqual(ViewMode.grid.displayName, "Grid")
        XCTAssertEqual(ViewMode.list.displayName, "List")
        XCTAssertEqual(ViewMode.grid.systemImageName, "square.grid.2x2")
        XCTAssertEqual(ViewMode.list.systemImageName, "list.bullet")
    }

    func testNaturalSortAndStrictDescendingOrder() {
        let fixture = TreeFixture()
        let items = [fixture.file("file10"), fixture.file("file2"), fixture.directory("z")]
        XCTAssertEqual(ItemSort().sorted(items).map(\.name), ["z", "file2", "file10"])
        XCTAssertEqual(ItemSort(ascending: false).sorted(items).map(\.name), ["z", "file10", "file2"])
        // ASCII digit ordering is portable; exotic localized collation is deliberately not asserted.
        for field in ItemSort.Field.allCases {
            for ascending in [true, false] {
                let sort = ItemSort(field: field, ascending: ascending, directoriesFirst: false)
                for a in items {
                    XCTAssertFalse(sort.compare(a, a))
                    for b in items where a != b { XCTAssertFalse(sort.compare(a, b) && sort.compare(b, a)) }
                }
            }
        }
        XCTAssertEqual(ItemSort().toggling(field: .name).ascending, false)
        XCTAssertEqual(ItemSort(ascending: false).toggling(field: .size).ascending, true)
        XCTAssertTrue(ItemSort().sorted([]).isEmpty)
    }

    func testSortFieldsAndRelevance() {
        let a = FileEntry(url: URL(fileURLWithPath: "/a"), size: 20,
                          modificationDate: Date(timeIntervalSince1970: 20), localizedKindDescription: "Zulu")
        let b = FileEntry(url: URL(fileURLWithPath: "/b"), size: 10,
                          modificationDate: Date(timeIntervalSince1970: 10), localizedKindDescription: "Alpha")
        for field in [ItemSort.Field.size, .dateModified, .kind] {
            XCTAssertEqual(ItemSort(field: field).sorted([a, b]), [b, a])
            XCTAssertEqual(ItemSort(field: field, ascending: false).sorted([a, b]), [a, b])
        }
        XCTAssertEqual(ItemSort.relevance.sorted([a, b], rankByID: [b.id: 0]), [b, a])
        XCTAssertFalse(ItemSort.relevance.directoriesFirst)
    }

    func testGenerationBoundary() {
        XCTAssertEqual(Generation().next().rawValue, 1)
        XCTAssertLessThan(Generation(), Generation(rawValue: 2))
        XCTAssertEqual(Generation(rawValue: .max).next(), Generation())
    }
}
