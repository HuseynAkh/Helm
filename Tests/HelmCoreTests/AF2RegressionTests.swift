import Foundation
import XCTest
@testable import HelmCore

final class AF2RegressionTests: XCTestCase {
    func testSameDirectoryPreservesState() {
        let home = URL(fileURLWithPath: "/home")
        var state = TabState(location: .directory(URL(fileURLWithPath: "/a/", isDirectory: true)), homeDirectory: home)
        state.selection = [ItemID(url: URL(fileURLWithPath: "/a/file"))]
        let (next, effects) = TabReducer.reduce(state, .navigate(.directory(URL(fileURLWithPath: "/a", isDirectory: false)), .push), context: ReducerContext(now: .distantPast, homeDirectory: home))
        XCTAssertEqual(next, state)
        XCTAssertTrue(effects.isEmpty)
    }
    func testVirtualLocationAndPropertiesCommands() {
        for kind: LocationKind in [.recent, .trash] {
            XCTAssertEqual(CommandValidation.state(for: .location, in: CommandContext(locationKind: kind)), .enabled)
        }
        for count in 0...2 {
            XCTAssertEqual(CommandValidation.state(for: .properties, in: CommandContext(selectionCount: count, hasMutationTarget: true)), count < 2 ? .enabled : .disabled)
        }
    }
    func testTabRefreshPreservesCaret() {
        let root = URL(fileURLWithPath: "/")
        var state = AddressEditorState(currentDirectory: root, home: root)
        state = AddressEditor.reduce(state, .beginEditing).0
        state = AddressEditor.reduce(state, .caretChanged(atEnd: false)).0
        XCTAssertFalse(AddressEditor.reduce(state, .tab).0.caretAtEnd)
    }
    func testVirtualCommitResetsAddressDirectory() {
        let home = URL(fileURLWithPath: "/home")
        let context = ReducerContext(now: .distantPast, homeDirectory: home)
        var state = TabState(location: .directory(URL(fileURLWithPath: "/deep")), homeDirectory: home)
        state = TabReducer.reduce(state, .navigate(.recent, .push), context: context).0
        state = TabReducer.reduce(state, .loadFinished(state.loadGeneration, SnapshotBuilder.build(location: .recent, entries: [])), context: context).0
        XCTAssertEqual(state.addressBar.currentDirectory, home)
    }
    func testModifierOrder() {
        XCTAssertEqual(KeyBinding(command: .newFolder, key: "N").displayString, "⇧⌘N")
    }
    func testRootRelativePath() {
        let root = URL(fileURLWithPath: "/")
        let entry = PathEntry(text: "Users", currentDirectory: root, home: root)
        XCTAssertEqual(entry.resolvedURL.path, "/Users")
        XCTAssertEqual(entry.directory.path, "/")
    }
}
