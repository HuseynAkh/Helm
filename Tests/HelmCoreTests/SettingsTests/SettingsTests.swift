import XCTest
import HelmCore

final class SettingsTests: XCTestCase {
    private struct Reader: SettingsReading {
        let values: [SettingKey: SettingValue]
        func value(for key: SettingKey) -> SettingValue? { values[key] }
    }
    func testAllDefaultsAndExactKeys() {
        let snapshot = SettingsSnapshot()
        XCTAssertEqual(snapshot.values.count, 23)
        for key in SettingKey.allCases {
            XCTAssertEqual(key.rawValue, "helm.\(key)")
            XCTAssertEqual(snapshot[key], SettingsSchema.defaultValue(for: key))
        }
        XCTAssertEqual(snapshot.double(.gridIconSize), 96)
        XCTAssertFalse(snapshot.bool(.confirmBeforeTrash))
        XCTAssertFalse(snapshot.bool(.askOnConflict))
        XCTAssertEqual(snapshot.string(.crossVolumeDragDefault), "copy")
        XCTAssertEqual(snapshot.defaultViewMode, .grid)
        XCTAssertEqual(snapshot.defaultSort, .defaultSort)
        XCTAssertFalse(snapshot.showHiddenFiles)
        XCTAssertFalse(SettingsSchema.appliesLive(.defaultViewMode))
        XCTAssertTrue(SettingsSchema.appliesLive(.gridIconSize))
    }
    func testValidationAndReader() throws {
        let snapshot = SettingsSnapshot(reader: Reader(values: [
            .gridIconSize: .double(64), .confirmBeforeTrash: .bool(true),
            .searchResultLimit: .integer(9000), .searchDebounceMilliseconds: .integer(-1),
            .maxCachedIcons: .integer(-1), .maxCachedThumbnails: .integer(-1),
            .completionDebounceMilliseconds: .integer(-1), .directoryCacheTTL: .double(.nan),
            .defaultViewMode: .string("column"), .defaultSortField: .string("dateModified"),
            .showHiddenFiles: .string("true")
        ]))
        XCTAssertEqual(snapshot.double(.gridIconSize), 64)
        XCTAssertTrue(snapshot.bool(.confirmBeforeTrash))
        XCTAssertEqual(snapshot.integer(.searchResultLimit), 800)
        XCTAssertEqual(snapshot.integer(.searchDebounceMilliseconds), 40)
        XCTAssertEqual(snapshot.integer(.maxCachedIcons), 100)
        XCTAssertEqual(snapshot.integer(.maxCachedThumbnails), 50)
        XCTAssertEqual(snapshot.integer(.completionDebounceMilliseconds), 30)
        XCTAssertEqual(snapshot.double(.directoryCacheTTL), 1.5)
        XCTAssertEqual(snapshot.defaultViewMode, .grid)
        XCTAssertEqual(snapshot.defaultSort.field, .dateModified)
        XCTAssertFalse(snapshot.showHiddenFiles)
        XCTAssertEqual(try JSONDecoder().decode(SettingsSnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        XCTAssertEqual(SettingsSchema.validated(.double(-5), for: .gridIconSize), .double(48))
        XCTAssertEqual(SettingsSchema.validated(.double(500), for: .directoryCacheTTL), .double(5))
        XCTAssertEqual(SettingsSchema.validated(.string("bad"), for: .crossVolumeDragDefault), .string("copy"))
        XCTAssertEqual(snapshot.integer(.showHiddenFiles), 0)
        XCTAssertEqual(snapshot.double(.showHiddenFiles), 0)
        XCTAssertEqual(snapshot.string(.showHiddenFiles), "")
    }
}
