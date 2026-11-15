import XCTest
import HelmAgent
@testable import HelmCore
@testable import HelmUI

/// HelmCore can't see HelmAgent, so the two pieces of AI mode's wording it shows hold the same words as literals.
/// These keep them equal to `AgentText`, which is where every AI mode string lives.
final class AgentTextPinsTests: XCTestCase {
    func testTheViewMenuRowReadsAsAgentTextSaysIt() {
        let rows = MenuModel.menuBar.flatMap(\.sections).flatMap { $0 }.filter { $0.command == .aiPanel }
        XCTAssertEqual(rows.count, 1, "one View menu row shows and hides the AI panel")
        XCTAssertEqual(rows.first?.title, AgentText.menuShowPanel)
    }

    func testTheFindWithAIRowReadsAsTheSearchToggleDoesAndTakesOptionCommandF() {
        let rows = MenuModel.menuBar.flatMap(\.sections).flatMap { $0 }.filter { $0.command == .findWithAI }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.title, AgentText.searchToggle)
        XCTAssertEqual(rows.first?.binding, KeyBinding(command: .findWithAI, key: "f", modifiers: [.command, .option]))
        let file = MenuModel.menuBar.first { $0.title == "File" }
        let section = file?.sections.first { $0.contains { $0.command == .find } }
        XCTAssertEqual(section?.map(\.command), [.find, .findWithAI], "beside Find")
        XCTAssertEqual(MenuModel.defaultBindings.filter { $0.key == "f" && $0.modifiers == [.command, .option] }.count, 1,
                       "no other command takes ⌥⌘F")
    }

    func testTheNoResultsButtonReadsAsTheSearchToggleDoes() {
        let home = URL(fileURLWithPath: "/home/helm", isDirectory: true)
        let folder = Location.directory(home.appendingPathComponent("Documents", isDirectory: true))
        var tab = TabState(location: folder, homeDirectory: home)
        tab.search = SearchState(query: SearchQuery(text: "invoice", scope: .home, bookmarkPaths: [], homeDirectory: home,
                                                    lastDirectory: nil, showHidden: false, limit: 100),
                                 isGathering: false)
        tab.snapshot = PresentationSnapshot(location: folder, phase: .ready, sortedEntries: [])
        let page = ContentStatePresentation.state(for: tab, home: home, fullDiskAccess: .granted, aiSearchReady: true)
        let button = page?.buttons.first { $0.action == .findWithAI }
        XCTAssertEqual(button?.title, AgentText.searchToggle)
    }
}
