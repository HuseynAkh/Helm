#if os(macOS)
import AppKit
import SwiftUI
import XCTest
import HelmAgent
import HelmCore
@testable import HelmUI

/// Where a plan's moves and copies go, as the card draws it on this Mac: the destination folder's path with the
/// home folder as "~", "new folder" when the plan makes it, shorter forms that keep the last folder for a narrow
/// panel, and one compact line that fits the card at the panel's narrowest and widest, light and dark.
@MainActor final class AgentPlanPathTests: XCTestCase {
    private let home = "/Users/someone"

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    // MARK: The words

    func testTheHomeFolderReadsAsATilde() {
        let homes = AgentPlanPath.homes(home)
        XCTAssertEqual(AgentPlanPath.compact(home + "/Documents/Screenshots", homes: homes), "~/Documents/Screenshots")
        XCTAssertEqual(AgentPlanPath.compact(home, homes: homes), "~")
        XCTAssertEqual(AgentPlanPath.compact("/private" + home + "/Desktop", homes: homes), "~/Desktop", "as macOS spells it too")
        XCTAssertEqual(AgentPlanPath.compact("/Users/someoneelse/Desktop", homes: homes), "/Users/someoneelse/Desktop",
                       "a folder whose name only starts like the home's is not in it")
        XCTAssertEqual(AgentPlanPath.compact("/Volumes/Share/Team", homes: homes), "/Volumes/Share/Team")
        XCTAssertEqual(AgentPlanPath.homes(home + "/"), [home, "/private" + home])
        XCTAssertEqual(AgentPlanPath.homes("/private/tmp/home"), ["/private/tmp/home", "/tmp/home"])
        XCTAssertEqual(AgentPlanPath.homes(""), [])
        XCTAssertEqual(AgentPlanPath.compact("/tmp/x", homes: []), "/tmp/x")
    }

    func testANameInThePathIsShownEscaped() {
        let path = AgentPlanPath(path: home + "/Documents/Line\u{2028}Break", homes: AgentPlanPath.homes(home), isNew: false)
        XCTAssertEqual(path.whole, "~/Documents/" + AgentTextEscaper.escape("Line\u{2028}Break"))
        XCTAssertFalse(path.whole.contains("\u{2028}"))
    }

    func testShorterFormsLeaveOutTheMiddleAndKeepTheLastFolder() {
        XCTAssertEqual(AgentPlanPath.forms(of: "~/Documents/Work/2026/Screenshots"),
                       ["~/Documents/Work/2026/Screenshots", "~/Documents/Work/…/Screenshots", "~/Documents/…/Screenshots",
                        "~/…/Screenshots"])
        XCTAssertEqual(AgentPlanPath.forms(of: "~/Documents/Screenshots"), ["~/Documents/Screenshots", "~/…/Screenshots"])
        XCTAssertEqual(AgentPlanPath.forms(of: "/Volumes/Share/Team"), ["/Volumes/Share/Team", "/Volumes/…/Team", "/…/Team"])
        XCTAssertEqual(AgentPlanPath.forms(of: "~/Desktop"), ["~/Desktop"])
        XCTAssertEqual(AgentPlanPath.forms(of: "~"), ["~"])
        for forms in [AgentPlanPath.forms(of: "~/a/b/c/d/e"), AgentPlanPath.forms(of: "/a/b/c")] {
            XCTAssertEqual(forms.map(\.count), forms.map(\.count).sorted(by: >), "each form is shorter than the one before")
            XCTAssertTrue(forms.allSatisfy { $0.hasSuffix("/" + (forms[0].split(separator: "/").last.map(String.init) ?? "")) })
        }
    }

    // MARK: The card

    private func item(_ path: String, folder: Bool = false) -> AgentPlanItem {
        AgentPlanItem(handle: path, rootAlias: "r1", path: path, name: (path as NSString).lastPathComponent,
                      kind: folder ? .directory : .regular, identity: nil, isDataless: false)
    }

    private func name(_ text: String) -> ValidFileName {
        guard let name = ValidFileName(text) else { fatalError(text) }
        return name
    }

    /// Six screenshots into a new folder two levels down, two notes into a folder that exists, and one copy.
    private func plan(names: [String] = (1...6).map { "Screen Shot 2026-11-1\($0).png" }, deeper: String = "Screenshots") -> AgentChangePlan {
        let documents = item(home + "/Documents", folder: true)
        let notes = item(home + "/Documents/Notes", folder: true)
        var steps: [AgentPlanStep] = [.newFolder(key: "n1", parent: .existing(documents), name: name("Pictures")),
                                      .newFolder(key: "n2", parent: .new(key: "n1"), name: name(deeper))]
        steps += names.map { .move(item(home + "/Documents/" + $0), to: .new(key: "n2")) }
        steps += [.move(item(home + "/Documents/memo.txt"), to: .existing(notes)), .copy(item(home + "/Documents/todo.txt"), to: .existing(notes))]
        let shots = Array(0..<(names.count + 2))
        return AgentChangePlan(title: .organize(rootLabel: "Documents"), steps: steps, groups: [
            AgentPlanGroup(id: 0, kind: .moves(toLabel: deeper, isNew: true), steps: shots),
            AgentPlanGroup(id: 1, kind: .moves(toLabel: "Notes", isNew: false), steps: [names.count + 2]),
            AgentPlanGroup(id: 2, kind: .copies(toLabel: "Notes", isNew: false), steps: [names.count + 3]),
        ], notices: [], leftOut: [:])
    }

    func testEachGroupSaysWhereItGoes() {
        let card = AgentPlanCard(plan: plan(), roots: [], home: home)
        XCTAssertEqual(card.groupRows.map(\.title), ["Move 6 items to “Screenshots”", "Move 1 item to “Notes”", "Copy 1 item to “Notes”"])
        XCTAssertEqual(card.groupRows.map { $0.destination?.whole }, ["~/Documents/Pictures/Screenshots", "~/Documents/Notes", "~/Documents/Notes"])
        XCTAssertEqual(card.groupRows.map { $0.destination?.isNew }, [true, false, false], "only the folder the plan makes is new")
        XCTAssertEqual(card.groupRows[0].destination?.forms.last, "~/…/Screenshots")
    }

    func testAnOpenGroupsRowsShowWhereEachItemGoes() {
        var card = AgentPlanCard(plan: plan(), roots: [], home: home)
        card.toggleOpen(0)
        let rows = card.groupRows[0].rows
        XCTAssertEqual(rows.count, 8, "the two new folders the moves go into, then the six moves")
        XCTAssertEqual(rows.map { $0.destination?.whole }, ["~/Documents", "~/Documents/Pictures"]
                       + Array(repeating: "~/Documents/Pictures/Screenshots", count: 6), "a new folder's row says where it is made")
        XCTAssertEqual(rows.map(\.detail), Array(repeating: "", count: 8), "where it goes, in place of where it is now")
        XCTAssertTrue(rows.allSatisfy { $0.destination?.isNew == false }, "the group says new folder once")
        XCTAssertEqual(rows.prefix(2).map(\.tags), [[AgentText.tagNew], [AgentText.tagNew]])
    }

    func testOtherGroupsKeepTheirLines() {
        let renames = AgentChangePlan(title: .rename(1), steps: [.rename(item(home + "/Documents/a.txt"), to: name("b.txt"))],
                                      groups: [AgentPlanGroup(id: 0, kind: .renames, steps: [0])], notices: [], leftOut: [:])
        let card = AgentPlanCard(plan: renames, roots: [], home: home)
        XCTAssertNil(card.groupRows[0].destination)
        XCTAssertNil(card.groupRows[0].rows[0].destination)
        XCTAssertEqual(card.groupRows[0].rows[0].detail, "Documents")
    }

    func testThePathIsDrawnPlainlyWithItsTooltip() {
        let path = AgentPlanPath(path: home + "/Documents/Pictures/Screenshots", homes: AgentPlanPath.homes(home), isNew: true)
        let view = AgentPlanPathView(path: path)
        XCTAssertEqual(path.forms, ["~/Documents/Pictures/Screenshots", "~/Documents/…/Screenshots", "~/…/Screenshots"])
        XCTAssertNotNil(view.body, "it builds")
        XCTAssertEqual(AgentText.pathNewFolder, "new folder")
    }

    // MARK: The layout

    /// The card drawn alone at a width, with clear room on each side. Answers whether anything was drawn in that
    /// room, which is where anything too wide for the card goes, and whether the card drew at all.
    private func drawn<V: View>(_ view: V, width: CGFloat, dark: Bool) throws -> (outside: Int, inside: Int, height: CGFloat) {
        let margin: CGFloat = 40
        let host = NSHostingView(rootView: view.frame(width: width).padding(.horizontal, margin).padding(.vertical, 4))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width + 2 * margin, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        let height = host.fittingSize.height
        host.frame = NSRect(x: 0, y: 0, width: width + 2 * margin, height: height)
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        let left = Int((margin - 1) * scale), right = Int((margin + width + 1) * scale)
        var outside = 0, inside = 0
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let alpha = rep.colorAt(x: x, y: y)?.alphaComponent, alpha > 0.02 else { continue }
                if x < left || x > right { outside += 1 } else { inside += 1 }
            }
        }
        return (outside, inside, height)
    }

    /// The card inside the thread: the panel's width less the thread's padding on each side.
    private func cardWidth(panel: CGFloat) -> CGFloat { panel - 24 }

    func testTheCheckSeesTextTooWideForTheCard() throws {
        let tooWide = Text(verbatim: String(repeating: "Screenshots ", count: 20)).fixedSize()
        let result = try drawn(tooWide, width: cardWidth(panel: AgentPanelHost.minimumWidth), dark: false)
        XCTAssertGreaterThan(result.outside, 0, "text past the card's edge is seen")
    }

    func testTheCardFitsAtTheNarrowestAndWidestPanelInLightAndDark() throws {
        let long = ["A screenshot with a very long name that goes on and on 2026-11-15 at 09.41.27.png", "short.png"]
        let plans = [plan(), plan(names: long, deeper: "Screenshots and screen recordings from the whole of last year")]
        for plan in plans {
            var card = AgentPlanCard(plan: plan, roots: [], home: home)
            for group in card.groupRows.map(\.id) where !card.groupRows.first(where: { $0.id == group })!.isOpen { card.toggleOpen(group) }
            let view = AgentPlanCardView(card: card, toggle: { _ in }, toggleOpen: { _ in }, apply: {}, cancel: {})
            for panel in [AgentPanelHost.minimumWidth, AgentPanelHost.maximumWidth] {
                for dark in [false, true] {
                    let result = try drawn(view, width: cardWidth(panel: panel), dark: dark)
                    XCTAssertEqual(result.outside, 0, "nothing is drawn past the card at \(panel) points, \(dark ? "dark" : "light")")
                    XCTAssertGreaterThan(result.inside, 0)
                    // Each group, open, is its title, its path and its rows, one line each: nothing wraps into a pile.
                    XCTAssertLessThan(result.height, 400, "\(panel) points")
                }
            }
        }
    }
}
#endif
