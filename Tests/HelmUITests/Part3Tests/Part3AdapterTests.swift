// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04
import Foundation
import XCTest
import HelmCore
import HelmSearch
@testable import HelmUI

final class Part3AdapterTests: XCTestCase {
    func testOptionsRoundTripAndIndependentGrouping() {
        let original = ViewOptions(viewMode: .list, sort: .relevance, groupBy: .tag,
                                   iconSize: 128, showColumns: [.name, .location, .tags], textSize: 16)
        var model = ViewOptionsModel(options: original)
        XCTAssertEqual(model.options, original)
        model.groupBy = .size
        XCTAssertEqual(model.options.sort, original.sort)
        XCTAssertEqual(model.options.groupBy, .size)
        XCTAssertEqual(model.options.showColumns, original.showColumns)
    }
    func testOptionsUsesCoreValidation() {
        var model = ViewOptionsModel(options: ViewOptions())
        model.columns = []; model.iconSize = .nan; model.textSize = 100
        XCTAssertEqual(model.options.showColumns, [.name])
        XCTAssertEqual(model.options.iconSize, 96)
        XCTAssertEqual(model.options.textSize, 32)
        for column in ListColumn.allCases { XCTAssertFalse(ViewOptionsModel.label(column.rawValue).isEmpty) }
        XCTAssertEqual(ViewOptionsModel.label("dateModified"), "Date Modified")
        XCTAssertEqual(ViewOptionsModel.label("dateCreated"), "Date Created")
        XCTAssertEqual(ViewOptionsModel.label("dateAdded"), "Date Added")
        XCTAssertEqual(ViewOptionsModel.label("dateLastOpened"), "Date Last Opened")
        XCTAssertEqual(ViewOptionsModel.groups.count, 5)
    }
    func testTagEditsPreserveUnknownMetadata() {
        let unknown = FinderTag(rawValue: "Legacy\n99")
        var model = TagEditorModel(tags: TagSet(tags: [unknown]), name: " Work ", color: .blue)
        model.add()
        let added = FinderTag(name: "Work", colorIndex: 4)
        XCTAssertEqual(model.tags.tags, [unknown, added])
        XCTAssertEqual(model.name, "")
        model.name = " Work "
        model.color = .red
        XCTAssertFalse(model.canAdd)
        model.add()
        XCTAssertEqual(model.tags.tags.count, 2)
        model.remove(added)
        XCTAssertEqual(model.tags.tags, [unknown])
        model.remove(added)
        XCTAssertEqual(model.tags.tags, [unknown])
    }
    func testTagRejectsBlankAndEmbeddedControlCharacters() {
        for text in ["", " \n ", "a\nb", "a\u{0}b", "a\tb"] {
            var model = TagEditorModel(tags: TagSet(), name: text)
            XCTAssertNil(model.proposedTag)
            model.add()
            XCTAssertTrue(model.tags.tags.isEmpty)
        }
        for color in FinderTagColor.allCases { XCTAssertFalse(TagEditorModel.label(color).isEmpty) }
        XCTAssertNotNil(TagEditorModel(tags: TagSet(), name: "旅行 🧭").proposedTag)
    }
    func testSearchScopesAndLiteralText() throws {
        let folder = URL(fileURLWithPath: "/Users/CaseSensitive")
        var model = SearchBarModel(text: "  report OR name:*  ", scope: .thisFolder,
                                   kind: .regular, folder: folder, includeHidden: true)
        let request = try XCTUnwrap(model.request)
        XCTAssertEqual(request.scope, .currentFolder(folder))
        XCTAssertEqual(request.text, "report OR name:*")
        XCTAssertEqual(request.filters, [.kind(.regular)])
        XCTAssertTrue(request.includeHidden)
        model.scope = .home; XCTAssertEqual(model.request?.scope, .home)
        model.scope = .thisMac; XCTAssertEqual(model.request?.scope, .thisMac)
        model.scope = .recents; XCTAssertEqual(model.request?.scope, .recents)
        model.kind = nil; XCTAssertEqual(model.request?.filters, [])
        model.text = " \n "; XCTAssertNil(model.request)
    }
    func testMissingFolderNeverWidensSearch() {
        var model = SearchBarModel(text: "query", scope: .thisFolder)
        XCTAssertTrue(model.scopeUnavailable); XCTAssertNil(model.request)
        model.folder = URL(string: "https://example.invalid/path")
        XCTAssertTrue(model.scopeUnavailable); XCTAssertNil(model.request)
        model.folder = URL(fileURLWithPath: "/")
        XCTAssertFalse(model.scopeUnavailable); XCTAssertNotNil(model.request)
    }
    func testFeedbackStatesAndLocationColumn() {
        XCTAssertNil(SearchBarStatus.idle.message)
        XCTAssertNil(SearchBarStatus.results.message)
        let states: [SearchBarStatus] = [.gathering, .noResults, .denied("Private"), .cancelled, .failed("Offline")]
        XCTAssertEqual(Set(states.compactMap(\.message)).count, states.count)
        let first = SearchLocationColumnModel(resultURL: URL(fileURLWithPath: "/One/report.txt"))
        let second = SearchLocationColumnModel(resultURL: URL(fileURLWithPath: "/Two/report.txt"))
        XCTAssertEqual(first.text, "/One")
        XCTAssertNotEqual(first.text, second.text)
        XCTAssertEqual(first.enclosingURL.path, "/One")
        XCTAssertEqual(first.accessibilityLabel, "Location: /One")
    }
    func testToolbarRequiresKeyboardRoutesEvenWhenFieldsVisible() {
        var model = ToolbarCustomizationModel(reachableKeyboardCommands: [])
        XCTAssertFalse(model.canApply)
        XCTAssertEqual(model.issues.count, 2)
        model.reachableKeyboardCommands = [.focusLocation, .focusSearch]
        model.items = []
        XCTAssertTrue(model.canApply)
        XCTAssertEqual(ToolbarCustomizationModel.requiredCommands, [.location, .find])
    }
    func testToolbarAddRemoveReorderAndDefaults() {
        var model = ToolbarCustomizationModel(items: [.sidebar, .search, .location],
                                             reachableKeyboardCommands: [.focusLocation, .focusSearch])
        model.add(.search); XCTAssertEqual(model.items.count, 3)
        model.add(.flexibleSpace); model.add(.flexibleSpace)
        XCTAssertTrue(model.canApply)
        model.move(from: 0, to: 2)
        XCTAssertEqual(Array(model.items.prefix(3)), [.search, .location, .sidebar])
        model.move(from: 2, to: 0)
        XCTAssertEqual(Array(model.items.prefix(3)), [.sidebar, .search, .location])
        let before = model.items
        model.move(from: -1, to: 0); model.move(from: 0, to: 999); model.move(from: 0, to: 0)
        model.remove(at: -1); model.remove(at: 999)
        XCTAssertEqual(model.items, before)
        model.remove(at: 0); XCTAssertEqual(model.items.first, .search)
        model.items.append(.search); XCTAssertFalse(model.canApply)
        model.restoreDefaults(); XCTAssertEqual(model.items, HelmCore.ToolbarItem.defaultLayout)
        XCTAssertTrue(model.canApply)
        for item in HelmCore.ToolbarItem.allCases { XCTAssertFalse(ToolbarCustomizationModel.label(item).isEmpty) }
    }
}
