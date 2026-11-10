// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore

final class K13SettingsTests: XCTestCase {
    /// F-065: schema defaults are fixed points.
    func testEveryDefaultIsValid() throws {
        for key in SettingKey.allCases { XCTAssertEqual(SettingsSchema.validated(SettingsSchema.defaultValue(for: key), for: key), SettingsSchema.defaultValue(for: key)) }
    }
    /// F-065: clamps avoid arithmetic overflow.
    func testIntegerExtremes() throws {
        XCTAssertEqual(SettingsSchema.validated(.integer(Int.min), for: .searchResultLimit), .integer(50))
        XCTAssertEqual(SettingsSchema.validated(.integer(Int.max), for: .searchResultLimit), .integer(800))
    }
    /// F-065: NaN and infinities cannot enter snapshots.
    func testNonFiniteDoubles() throws {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(SettingsSchema.validated(.double(value), for: .gridIconSize), .double(96))
            XCTAssertEqual(SettingsSchema.validated(.double(value), for: .directoryCacheTTL), .double(1.5))
        }
    }
    /// F-065: persisted types are strict.
    func testNoBooleanNumericCoercion() throws {
        XCTAssertEqual(SettingsSchema.validated(.integer(1), for: .showHiddenFiles), .bool(false))
        XCTAssertEqual(SettingsSchema.validated(.bool(true), for: .searchResultLimit), .integer(300))
    }
    /// F-065: unknown keys cannot affect known preferences.
    func testUnknownKeysDiscarded() throws {
        let snapshot = SettingsSnapshot(values: ["future": .string("x"), SettingKey.defaultViewMode.rawValue: .string("LIST")])
        XCTAssertNil(snapshot.values["future"])
        XCTAssertEqual(snapshot.defaultViewMode, .grid)
    }
    /// F-065: decoding follows the same clamps as construction.
    func testDecodedSnapshotRevalidates() throws {
        let data = try JSONEncoder().encode(["values": [SettingKey.gridIconSize.rawValue: SettingValue.double(-100)]])
        XCTAssertEqual(try JSONDecoder().decode(SettingsSnapshot.self, from: data).double(.gridIconSize), 48)
    }
}
