// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import XCTest
import HelmCore
@testable import HelmUI

final class SettingsBindingsTests: XCTestCase {
    @MainActor
    func testBindingsReadSnapshotAndEmitTypedIntentsWithoutMutation() {
        let snapshot = SettingsSnapshot()
        var changes: [(SettingKey, SettingValue)] = []
        let view = SettingsPaneView(pane: .general, snapshot: snapshot) { changes.append(($0, $1)) }
        XCTAssertFalse(view.bool(.showHiddenFiles).wrappedValue)
        XCTAssertEqual(view.string(.defaultViewMode).wrappedValue, "grid")
        XCTAssertEqual(view.number(.gridIconSize).wrappedValue, 96)
        XCTAssertEqual(view.integer(.searchResultLimit).wrappedValue, 300)
        view.bool(.showHiddenFiles).wrappedValue = true
        view.string(.defaultViewMode).wrappedValue = "list"
        view.number(.gridIconSize).wrappedValue = 112
        view.integer(.searchResultLimit).wrappedValue = 400
        XCTAssertEqual(changes.map { $0.0 }, [.showHiddenFiles, .defaultViewMode, .gridIconSize, .searchResultLimit])
        XCTAssertEqual(changes.map { $0.1 }, [.bool(true), .string("list"), .double(112), .integer(400)])
        XCTAssertFalse(view.bool(.showHiddenFiles).wrappedValue)
        XCTAssertFalse(view.supportsSingleClick)
    }

    @MainActor
    func testHostRefreshUpdatesBindingsAndOptionalCapability() {
        let snapshot = SettingsSnapshot(values: [SettingKey.gridIconSize.rawValue: .double(999),
                                                SettingKey.defaultViewMode.rawValue: .string("list")])
        let view = SettingsPaneView(pane: .view, snapshot: snapshot, supportsSingleClick: true) { _, _ in }
        XCTAssertEqual(view.number(.gridIconSize).wrappedValue, 128)
        XCTAssertEqual(view.string(.defaultViewMode).wrappedValue, "list")
        XCTAssertTrue(view.supportsSingleClick)
        XCTAssertEqual(SettingsPane.allCases.map(\.id), ["General", "Sidebar", "View", "Search", "Advanced"])
    }
}
