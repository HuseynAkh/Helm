// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
@testable import HelmCore

final class PresentationPropertiesAndToolbarTests: XCTestCase {
    func testPropertiesEmptySingleAndMixed() {
        let empty = PropertiesModel(entries: [])
        XCTAssertEqual(empty.itemCount, 0); XCTAssertEqual(empty.totalSize, 0)
        XCTAssertNil(empty.commonKind); XCTAssertFalse(empty.hasMixedKinds)
        let a = FileEntry(url: URL(fileURLWithPath: "/a"), size: 10, localizedKindDescription: "Document")
        let single = PropertiesModel(entries: [a, a])
        XCTAssertEqual(single.itemCount, 1); XCTAssertEqual(single.totalSize, 10)
        XCTAssertEqual(single.commonKind, .regular); XCTAssertEqual(single.commonKindDescription, "Document")
        let b = FileEntry(url: URL(fileURLWithPath: "/other/b"), kind: .directory, isHidden: true,
                          isReadable: false, size: 20, modificationDate: Date(), creationDate: Date())
        let mixed = PropertiesModel(entries: [a, b])
        XCTAssertEqual(mixed.directoryCount, 1); XCTAssertEqual(mixed.fileCount, 1)
        XCTAssertEqual(mixed.totalSize, 30); XCTAssertNil(mixed.commonKind)
        XCTAssertTrue(mixed.hasMixedKinds); XCTAssertTrue(mixed.hasMixedSizes)
        XCTAssertTrue(mixed.hasMixedLocations); XCTAssertTrue(mixed.hasMixedCreationDates)
        XCTAssertTrue(mixed.hasMixedModificationDates); XCTAssertTrue(mixed.hasMixedReadability)
        XCTAssertTrue(mixed.hasMixedHiddenState)
    }
    func testHugeAndUnknownSizes() {
        let entries = [Int64.max, 1, -1].enumerated().map { index, size in
            FileEntry(url: URL(fileURLWithPath: "/\(index)"), size: size)
        }
        let model = PropertiesModel(entries: entries)
        XCTAssertEqual(model.totalSize, .max); XCTAssertTrue(model.sizeOverflowed)
        XCTAssertTrue(model.hasUnknownSize)
    }
    func testToolbarLayoutAndKeyboardRoutes() {
        let routes: Set<ToolbarCommand> = [.focusLocation, .focusSearch]
        XCTAssertEqual(ToolbarItem.defaultLayout, [.sidebar, .navigation, .location, .viewMode, .search])
        for layout in [ToolbarItem.defaultLayout, [], [.flexibleSpace, .flexibleSpace]] {
            XCTAssertEqual(ToolbarLayoutValidation.validate(layout, reachableKeyboardCommands: routes), [])
        }
        XCTAssertEqual(ToolbarLayoutValidation.validate([.search, .search], reachableKeyboardCommands: [.focusSearch]),
                       [.duplicateItem(.search), .unreachableCommand(.focusLocation)])
        XCTAssertEqual(ToolbarLayoutValidation.validate(ToolbarItem.defaultLayout, reachableKeyboardCommands: []).count, 2)
        XCTAssertEqual(ToolbarCommand.focusLocation.keyEquivalent, "Cmd+L")
        XCTAssertEqual(ToolbarCommand.focusSearch.keyEquivalent, "Cmd+F")
        XCTAssertEqual(Set(ToolbarCommand.allCases.compactMap(\.keyEquivalent)).count, ToolbarCommand.allCases.count)
        for command in ToolbarCommand.allCases { XCTAssertTrue(ToolbarItem.defaultLayout.contains(command.toolbarItem)) }
    }
}
