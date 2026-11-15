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
        XCTAssertEqual(SettingsPane.allCases.map(\.id), ["General", "AI", "View", "Appearance", "Sidebar", "Search", "Advanced"])
        XCTAssertEqual(SettingsPane.sidebar.symbol, "sidebar.left")
    }

    /// Settings › AI is the second pane, right after General, and its tab is named AI. It draws Helm's spark rather
    /// than a symbol, and has a height of its own like every other pane.
    func testTheAIPaneComesSecond() {
        XCTAssertEqual(SettingsPane.allCases.first, .general)
        XCTAssertEqual(SettingsPane.allCases.dropFirst().first, .ai)
        XCTAssertEqual(SettingsPane.ai.rawValue, "AI")
        XCTAssertEqual(SettingsPane(rawValue: "AI"), .ai)
        XCTAssertEqual(SettingsPane.ai.symbol, "")
        XCTAssertGreaterThan(SettingsPane.ai.height, 0)
        // The other panes keep their order, names and symbols.
        XCTAssertEqual(SettingsPane.allCases.filter { $0 != .ai }.map(\.symbol),
                       ["gearshape", "square.grid.2x2", "circle.lefthalf.filled", "sidebar.left", "magnifyingglass", "slider.horizontal.3"])
    }
}
