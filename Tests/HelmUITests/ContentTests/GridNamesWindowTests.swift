#if os(macOS)
import AppKit
import XCTest
import HelmCore
@testable import HelmUI

/// Long names in the grid, in an offscreen window wired to the reducer as the window wires it: two lines cut in the
/// middle, the whole name while it's the one item selected, drawn over the items below, the tooltip, what VoiceOver
/// reads and the rename field. The list is checked to stay as it was.
@MainActor final class GridNamesWindowTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/gridnames")
    private var context: ReducerContext { ReducerContext(now: .distantPast, homeDirectory: root) }
    private let long = "Quarterly_Report_draft_v2_final_reviewed_by_finance_and_legal.pdf"
    /// Over 200 characters: more than five lines even while selected.
    private let veryLong = String(repeating: "A very long name with many words in it ", count: 6) + "and then its end.md"

    private func file(_ name: String, _ kind: FileEntryKind = .regular) -> FileEntry {
        FileEntry(url: root.appendingPathComponent(name), kind: kind)
    }
    private func loadedTab(_ entries: [FileEntry], location: Location? = nil, sort: ItemSort = .defaultSort) -> TabState {
        let place = location ?? .directory(root)
        var tab = TabState(location: place, homeDirectory: root)
        tab.sort = sort
        tab.isLoading = true
        let snapshot = SnapshotBuilder.build(location: place, entries: entries, sort: sort)
        return TabReducer.reduce(tab, .loadFinished(tab.loadGeneration, snapshot), context: context).0
    }
    private func harness(_ names: [String]) -> GridNamesHarness {
        GridNamesHarness(tab: loadedTab(names.map { file($0) }), context: context)
    }

    // MARK: The room a name has

    /// The name is given exactly the room the real label has. AppKit runs a text field's frame past its constraints,
    /// so the label is wider than the item less its insets; a word just too wide for that narrower width still fits
    /// on one line of the real label, so the name it starts stays whole on two lines.
    func testTheNameHasAllTheRoomTheLabelHas() throws {
        let font = NSFont.systemFont(ofSize: 14)
        let metrics = GridItemMetrics(iconSize: 96, lineHeight: GridNameMetrics.lineHeight(for: font))
        // A word wider than the item's width less its insets and margins, but no wider than the label's text.
        var word = "Quarterly_report"
        while GridNameShortener.measure(word + "i", font) <= metrics.textWidth { word += "i" }
        XCTAssertGreaterThan(GridNameShortener.measure(word, font), metrics.labelWidth - GridNameLabel.textInset)
        let name = word + " notes.txt"
        let h = harness([name, "b.txt"])
        let item = try XCTUnwrap(h.grid.itemForTesting(h.id(name)))
        XCTAssertEqual(item.labelFrameForTesting.width, h.metrics.labelFrameWidth, accuracy: 0.5, "the label's frame isn't the width worked out")
        let report = try XCTUnwrap(h.report(name))
        XCTAssertFalse(report.isShortened, "shortened, though the label fits it on two lines: \(report.lines)")
        XCTAssertEqual(report.lines, [word, "notes.txt"])
        XCTAssertEqual(report.drawnLines, 2)
        // At every icon size the label's frame is the width the name is worked out for.
        for icon in stride(from: 48, through: 128, by: 16) {
            h.host.gridIconSize = icon
            h.grid.render(h.tab, force: true)
            h.window.layoutIfNeeded()
            let resized = try XCTUnwrap(h.grid.itemForTesting(h.id(name)))
            XCTAssertEqual(resized.labelFrameForTesting.width, h.metrics.labelFrameWidth, accuracy: 0.5, "\(icon) icons")
        }
    }

    // MARK: Unselected

    /// A long name takes two lines: the start of the name, then more of it, the cut and the end, extension included.
    /// The tooltip has it whole. A name that fits is left alone, with no tooltip.
    func testALongNameTakesTwoLinesCutInTheMiddle() throws {
        let h = harness(["notes.txt", long, "Two words.md"])
        let short = try XCTUnwrap(h.report("notes.txt"))
        XCTAssertEqual(short.lines, ["notes.txt"])
        XCTAssertFalse(short.isShortened)
        XCTAssertNil(short.toolTip, "a name shown whole has no tooltip")
        let cut = try XCTUnwrap(h.report(long))
        XCTAssertEqual(cut.lines.count, 2, "\(cut.lines)")
        XCTAssertTrue(cut.isShortened)
        XCTAssertTrue(long.hasPrefix(cut.lines[0]), "the first line is the start of the name: \(cut.lines)")
        XCTAssertTrue(cut.lines[1].contains("…") && cut.lines[1].hasSuffix(".pdf"), "the second keeps the end: \(cut.lines)")
        XCTAssertEqual(cut.toolTip, long)
        XCTAssertFalse(cut.isExpanded)
        XCTAssertEqual(cut.overflow, 0)
        // The label draws exactly these lines: its height is two lines, inside the item.
        let item = try XCTUnwrap(h.grid.itemForTesting(h.id(long)))
        XCTAssertEqual(item.labelFrameForTesting.height, 2 * h.lineHeight, accuracy: 0.5)
        XCTAssertLessThanOrEqual(item.labelFrameForTesting.maxY, item.view.bounds.height)
        XCTAssertEqual(item.textField?.stringValue, cut.lines.joined(separator: "\n"))
    }

    /// VoiceOver reads the whole name, for the item and for the words under its icon, however they're shortened.
    func testVoiceOverReadsTheWholeName() throws {
        let app = FileEntry(url: root.appendingPathComponent("A Tool With A Really Long Application Name For Testing.app"), kind: .package)
        let h = GridNamesHarness(tab: loadedTab([file(long), file(veryLong), app]), context: context)
        for name in [long, veryLong] {
            let report = try XCTUnwrap(h.report(name))
            XCTAssertTrue(report.isShortened)
            XCTAssertEqual(report.spokenName, name)
            XCTAssertEqual(report.spokenWords, name)
        }
        h.select(veryLong)
        XCTAssertEqual(h.report(veryLong)?.spokenWords, veryLong, "five lines are still cut, and VoiceOver still reads it all")
        // An app shows without ".app", and so do its words; the item keeps its file name.
        let shownApp = try XCTUnwrap(h.report(app.name))
        XCTAssertEqual(shownApp.spokenWords, app.displayName)
        XCTAssertEqual(shownApp.spokenName, app.name)
        XCTAssertFalse(shownApp.lines.joined().contains(".app"))
    }

    // MARK: Selected

    /// Clicked, the one item shows its whole name, up to five lines, on a highlight that grows with it, drawn over
    /// the item below. Clicking elsewhere puts it back to two lines.
    func testTheOneSelectedItemShowsItsWholeNameOverTheItemsBelow() throws {
        // The fillers sort after the long name, so it's in the first row with items under it.
        let h = harness([long] + (1...11).map { "zz-file-\($0).txt" })
        h.select(long)
        let open = try XCTUnwrap(h.report(long))
        XCTAssertTrue(open.isExpanded)
        XCTAssertFalse(open.isShortened)
        XCTAssertGreaterThan(open.lines.count, 2)
        XCTAssertLessThanOrEqual(open.lines.count, 5)
        XCTAssertEqual(open.lines.joined(), long, "the whole name, wrapped")
        XCTAssertNil(open.toolTip, "nothing left out, so no tooltip")
        XCTAssertTrue(open.isOnTop, "drawn over the items around it")
        XCTAssertTrue(open.coversBelow, "the items under the name cut that part away, so they don't show through")
        XCTAssertEqual(open.overflow, CGFloat(open.lines.count - 2) * h.lineHeight, accuracy: 0.5)
        // The highlight grows with the name, past the bottom of the item and over the item below it.
        let item = try XCTUnwrap(h.grid.itemForTesting(h.id(long)))
        XCTAssertEqual(item.highlightFrameForTesting.height, item.view.bounds.height + open.overflow, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(item.highlightFrameForTesting.height, item.labelFrameForTesting.maxY)
        let collection = h.grid.collectionForTesting
        let frame = item.view.frame
        let under = NSRect(x: frame.minX, y: frame.maxY, width: frame.width, height: open.overflow)
        let covered = collection.visibleItems().filter { $0 !== item && $0.view.frame.intersects(under) }
        XCTAssertFalse(covered.isEmpty, "the name runs over the item below it")
        // A click elsewhere: back to two lines, under nothing.
        h.select("zz-file-2.txt")
        let closed = try XCTUnwrap(h.report(long))
        XCTAssertFalse(closed.isExpanded)
        XCTAssertEqual(closed.lines.count, 2)
        XCTAssertEqual(closed.overflow, 0)
        XCTAssertEqual(closed.toolTip, long)
        XCTAssertEqual(h.grid.layoutForTesting.raised, h.path("zz-file-2.txt"))
        h.send(.setSelection([], source: .user))
        XCTAssertNil(h.grid.layoutForTesting.raised)
    }

    /// Past five lines, a selected name is cut too, in the middle of the fifth, and the tooltip has it whole.
    func testPastFiveLinesTheSelectedNameIsCutToo() throws {
        XCTAssertGreaterThan(veryLong.count, 200)
        let h = harness([veryLong, "b.txt"])
        h.select(veryLong)
        let open = try XCTUnwrap(h.report(veryLong))
        XCTAssertEqual(open.lines.count, 5)
        XCTAssertTrue(open.isShortened)
        XCTAssertTrue(open.lines[4].contains("…") && open.lines[4].hasSuffix(" end.md"), "\(open.lines)")
        XCTAssertTrue(veryLong.hasPrefix(open.lines[0]), "\(open.lines)")
        XCTAssertEqual(open.toolTip, veryLong)
        XCTAssertEqual(open.overflow, 3 * h.lineHeight, accuracy: 0.5)
    }

    /// With several selected, each keeps its two lines, so the names never cover each other.
    func testSeveralSelectedKeepTheirTwoLines() throws {
        let other = "Another_very_long_file_name_that_needs_shortening_too.numbers"
        let h = harness([long, other, "c.txt"])
        h.select(long, other)
        for name in [long, other] {
            let report = try XCTUnwrap(h.report(name))
            XCTAssertFalse(report.isExpanded)
            XCTAssertEqual(report.lines.count, 2)
            XCTAssertEqual(report.overflow, 0)
        }
        XCTAssertNil(h.grid.layoutForTesting.raised)
    }

    /// The whole name is drawn over the item below, so a click on it lands on its own item, not on the one under it.
    func testAClickOnTheWholeNameLandsOnItsItem() throws {
        let h = harness([long] + (1...7).map { "zz-file-\($0).txt" })
        h.select(long)
        let open = try XCTUnwrap(h.report(long))
        let item = try XCTUnwrap(h.grid.itemForTesting(h.id(long)))
        let frame = item.view.frame
        let collection = h.grid.collectionForTesting
        let onName = NSPoint(x: frame.midX, y: frame.maxY + open.overflow / 2)
        XCTAssertEqual(collection.indexPathForItem(at: onName), h.path(long))
        // Past the end of the name, a click lands on the item below again.
        let pastName = NSPoint(x: frame.midX, y: frame.maxY + open.overflow + 4)
        XCTAssertNotEqual(collection.indexPathForItem(at: pastName), h.path(long))
    }

    /// In the last row the whole name runs past the end of the grid, so the grid grows to let it be scrolled to.
    func testTheGridGrowsForAWholeNameInTheLastRow() throws {
        // The fillers sort first, so the long name is in the last row.
        let h = harness((1...7).map { "0-file-\($0).txt" } + [veryLong])
        let before = h.grid.layoutForTesting.collectionViewContentSize.height
        h.select(veryLong)
        let open = try XCTUnwrap(h.report(veryLong))
        let item = try XCTUnwrap(h.grid.itemForTesting(h.id(veryLong)))
        let after = h.grid.layoutForTesting.collectionViewContentSize.height
        XCTAssertGreaterThan(after, before)
        XCTAssertGreaterThanOrEqual(after, item.view.frame.maxY + open.overflow)
        XCTAssertGreaterThanOrEqual(h.grid.collectionForTesting.frame.height, item.view.frame.maxY + open.overflow)
        h.send(.setSelection([], source: .user))
        XCTAssertEqual(h.grid.layoutForTesting.collectionViewContentSize.height, before, accuracy: 0.5)
    }

    // MARK: Renaming

    /// The rename field always has the whole name, however long, grows as it's typed, and sits over the items below.
    /// Escape puts the lines back.
    func testTheRenameFieldShowsTheWholeName() throws {
        let h = harness([veryLong, "b.txt", "c.txt", "d.txt", "e.txt", "f.txt"])
        h.select(veryLong)
        let entry = try XCTUnwrap(h.tab.snapshot.entry(h.id(veryLong)))
        h.grid.beginRename(entry)
        let editor = try XCTUnwrap(h.window.firstResponder as? NSTextView, "no rename field")
        XCTAssertEqual(editor.string, veryLong, "the field has the whole name, not the shortened lines")
        let editing = try XCTUnwrap(h.report(veryLong))
        XCTAssertEqual(editing.fieldWords, veryLong)
        XCTAssertTrue(editing.isOnTop)
        let item = try XCTUnwrap(h.grid.itemForTesting(h.id(veryLong)))
        let needed = GridNameMetrics.height(of: veryLong, labelWidth: h.metrics.labelFrameWidth, font: h.font)
        let height = item.labelFrameForTesting.height
        XCTAssertGreaterThanOrEqual(height, needed - 0.5, "the field is tall enough for the whole name")
        XCTAssertGreaterThan(height, 5 * h.lineHeight)
        // The editor's own lines fit in the field, so none of the name is scrolled out of view.
        func typedHeight() -> CGFloat {
            guard let layout = editor.layoutManager, let container = editor.textContainer else { return .infinity }
            layout.ensureLayout(for: container)
            return layout.usedRect(for: container).height
        }
        XCTAssertLessThanOrEqual(typedHeight(), height + 0.5)
        // Typing more makes it taller, still holding every line.
        editor.string = veryLong + " and some more words typed at the end of it to make it longer still"
        editor.didChangeText()
        XCTAssertGreaterThan(item.labelFrameForTesting.height, height)
        XCTAssertLessThanOrEqual(typedHeight(), item.labelFrameForTesting.height + 0.5)
        XCTAssertEqual(h.grid.layoutForTesting.raised, h.path(veryLong))
        XCTAssertEqual(h.grid.layoutForTesting.raisedOverflow, item.nameOverflow, accuracy: 0.5)
        // Escape: nothing renamed, and the five lines are back.
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertEqual(h.host.renames.count, 1)
        XCTAssertNil(h.host.renames.first ?? "renamed")
        let back = try XCTUnwrap(h.report(veryLong))
        XCTAssertNil(back.fieldWords)
        XCTAssertEqual(back.lines.count, 5)
        XCTAssertTrue(back.isShortened)
        XCTAssertEqual(h.grid.layoutForTesting.raisedOverflow, 3 * h.lineHeight, accuracy: 0.5)
    }

    /// Return with nothing typed renames nothing, and the item goes back to its lines.
    func testCommittingARenameGoesBackToTheLines() throws {
        let h = harness([long, "b.txt"])
        h.select(long)
        let entry = try XCTUnwrap(h.tab.snapshot.entry(h.id(long)))
        h.grid.beginRename(entry)
        XCTAssertTrue(h.window.firstResponder is NSTextView)
        h.window.makeFirstResponder(nil)
        XCTAssertEqual(h.host.renames.count, 1)
        let back = try XCTUnwrap(h.report(long))
        XCTAssertNil(back.fieldWords)
        XCTAssertTrue(back.isExpanded)
        XCTAssertEqual(back.lines.joined(), long)
    }

    // MARK: Recent and search

    /// Recent's two groups shorten their names the same way, and a selected name is drawn over the heading below too.
    func testRecentsGroupsShortenNamesToo() throws {
        func opened(_ name: String, _ kind: FileEntryKind, _ seconds: TimeInterval) -> FileEntry {
            var entry = file(name, kind)
            entry.lastOpenedDate = Date(timeIntervalSince1970: seconds)
            return entry
        }
        let folder = "A folder with a long name that will not fit on two lines of the grid at all"
        let entries = [opened(folder, .directory, 30), opened("Short", .directory, 20), opened(long, .regular, 10), opened("a.txt", .regular, 5)]
        let h = GridNamesHarness(tab: loadedTab(entries, location: .recent, sort: ItemSort(field: .lastOpened, ascending: false)), context: context)
        XCTAssertEqual(h.grid.sectionSummaryForTesting, ["Folders 2", "Files 2"])
        for name in [folder, long] {
            let report = try XCTUnwrap(h.report(name))
            XCTAssertEqual(report.lines.count, 2)
            XCTAssertTrue(report.isShortened)
            XCTAssertEqual(report.toolTip, name)
        }
        h.select(folder)
        let open = try XCTUnwrap(h.report(folder))
        XCTAssertTrue(open.isExpanded)
        XCTAssertFalse(open.isShortened)
        XCTAssertTrue(open.isOnTop, "over the items and the Files heading below")
        XCTAssertEqual(h.grid.layoutForTesting.raised, h.path(folder))
        // The Files heading is under the name, and cuts that part of itself away, as the items do.
        XCTAssertTrue(h.grid.viewsUnderNameForTesting(h.id(folder)).contains { $0 is GridSectionHeader }, "the heading isn't under the name")
        XCTAssertTrue(open.coversBelow, "the heading shows through the name")
    }

    /// Search results shorten and open up the same way.
    func testSearchResultsShortenNamesToo() throws {
        let h = harness(["plain.txt", long, "q.txt"])
        let query = SearchQuery(text: "q", scope: .currentFolder(root), bookmarkPaths: [], homeDirectory: root,
                                lastDirectory: nil, showHidden: false, limit: 100)
        h.send(.searchStarted(query))
        h.send(.searchResults(h.tab.searchGeneration, [SearchResult(entry: file(long), rank: 0), SearchResult(entry: file("q.txt"), rank: 1)]))
        let cut = try XCTUnwrap(h.report(long))
        XCTAssertEqual(cut.lines.count, 2)
        XCTAssertTrue(cut.isShortened)
        h.select(long)
        let open = try XCTUnwrap(h.report(long))
        XCTAssertTrue(open.isExpanded)
        XCTAssertEqual(open.lines.joined(), long)
        XCTAssertTrue(open.isOnTop)
    }

    // MARK: Sizes and looks

    /// At every text size and icon size: two lines that fit the item, five while selected, and every name drawn by
    /// the real label on exactly the lines worked out for it, whole or cut, none wrapped again.
    func testEveryTextSizeAndIconSize() throws {
        let names = [long, veryLong, "notes.txt", "日本語のとても長いファイル名のテストです。これは表示の確認用.txt", "Annual budget review.xlsx",
                     "한국어 문서.txt", "Two words.md", "Quarterly Report the.txt", "مستند طويل جدا للاختبار في عرض الشبكة مع اسم طويل.pdf"]
        let h = harness(names)
        for percent in stride(from: 80, through: 170, by: 10) {
            for icon in stride(from: 48, through: 128, by: 16) {
                h.host.fileTextSize = CGFloat(percent) / 100 * 14
                h.host.gridIconSize = icon
                h.grid.render(h.tab, force: true)
                h.window.layoutIfNeeded()
                h.send(.setSelection([], source: .user))
                for name in names {
                    let report = try XCTUnwrap(h.report(name))
                    XCTAssertEqual(report.drawnLines, report.lines.count, "\(percent)% text, \(icon) icons, “\(name)”: \(report.lines)")
                }
                for name in [long, veryLong] {
                    let report = try XCTUnwrap(h.report(name))
                    let item = try XCTUnwrap(h.grid.itemForTesting(h.id(name)))
                    let label = item.labelFrameForTesting
                    XCTAssertLessThanOrEqual(report.lines.count, 2, "\(percent)% text, \(icon) icons: \(report.lines)")
                    XCTAssertEqual(label.height, CGFloat(report.lines.count) * h.lineHeight, accuracy: 0.5)
                    XCTAssertLessThanOrEqual(label.maxY, item.view.bounds.height, "the name fits in its item at \(percent)%, \(icon)")
                    XCTAssertEqual(item.textField?.cell?.cellSize(forBounds: NSRect(origin: .zero, size: NSSize(width: label.width, height: 10_000))).height ?? 0,
                                   label.height, accuracy: 0.5, "a line wrapped again at \(percent)%, \(icon): \(report.lines)")
                }
                h.select(veryLong)
                let open = try XCTUnwrap(h.report(veryLong))
                XCTAssertEqual(open.lines.count, 5, "\(percent)% text, \(icon) icons")
                XCTAssertEqual(open.overflow, 3 * h.lineHeight, accuracy: 0.5)
                XCTAssertTrue(open.isOnTop)
            }
        }
    }

    /// In light and in dark, a whole name's highlight is the same see-through wash as any other selection, so a long
    /// name's highlight looks like a short one's whatever is behind the window. The items under the name cut that part
    /// of themselves away instead, so none of them shows through it, and they're whole again once it's deselected.
    func testTheItemsUnderAWholeNameAreCutAway() throws {
        let h = harness([veryLong] + (1...11).map { "zz-file-\($0).txt" })
        func components(_ color: NSColor?) -> [CGFloat] {
            guard let color = color?.usingColorSpace(.sRGB) else { return [] }
            return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
        }
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            h.window.appearance = NSAppearance(named: name)
            h.select("zz-file-1.txt")
            let short = components(h.grid.itemForTesting(h.id("zz-file-1.txt"))?.highlightFillForTesting)
            h.select(veryLong)
            let open = try XCTUnwrap(h.report(veryLong))
            XCTAssertTrue(open.isExpanded)
            XCTAssertGreaterThan(open.overflow, 0)
            let long = components(h.grid.itemForTesting(h.id(veryLong))?.highlightFillForTesting)
            XCTAssertEqual(long.count, 4)
            for (a, b) in zip(long, short) { XCTAssertEqual(a, b, accuracy: 0.01, "\(name.rawValue): \(long) against \(short)") }
            XCTAssertLessThan(long.last ?? 1, 1, "the wash is see-through, as for any selection")
            XCTAssertTrue(open.coversBelow, "\(name.rawValue): what's under the name shows through it")
        }
        let under = h.grid.viewsUnderNameForTesting(h.id(veryLong))
        XCTAssertFalse(under.isEmpty, "nothing under the name")
        for view in under {
            // The part under the name is cut away, and the part below the name is on show as ever.
            XCTAssertTrue(view.isCutAwayForTesting(at: NSPoint(x: view.frame.midX, y: view.frame.minY + 4)))
            XCTAssertFalse(view.isCutAwayForTesting(at: NSPoint(x: view.frame.midX, y: view.frame.maxY - 4)))
        }
        // Another item selected: nothing is cut away any more.
        h.select("zz-file-1.txt")
        let collection = h.grid.collectionForTesting
        XCTAssertTrue(collection.subviews.allSatisfy { $0.layer?.mask == nil }, "an item stayed cut away")
        // Several selected: the usual wash on each, and nothing cut away.
        h.select(veryLong, "zz-file-1.txt")
        XCTAssertLessThan(h.grid.itemForTesting(h.id(veryLong))?.highlightFillForTesting?.alphaComponent ?? 1, 1)
        XCTAssertTrue(collection.subviews.allSatisfy { $0.layer?.mask == nil })
    }

    /// A real click on the part of a whole name past its item, delivered to the view under the pointer as the window
    /// delivers it, keeps that item selected rather than picking the item under the name. A double-click there opens
    /// the item whose name it is.
    func testARealClickOnTheWholeNameLandsOnItsItem() throws {
        let h = harness([long] + (1...7).map { "zz-file-\($0).txt" })
        // A click on another item's icon selects that one, so the clicks get through.
        let other = try XCTUnwrap(h.grid.itemForTesting(h.id("zz-file-3.txt")))
        h.click(at: NSPoint(x: other.view.frame.midX, y: other.view.frame.minY + 40))
        XCTAssertEqual(h.grid.collectionForTesting.selectionIndexPaths, Set([h.path("zz-file-3.txt")].compactMap { $0 }))
        h.select(long)
        let open = try XCTUnwrap(h.report(long))
        let item = try XCTUnwrap(h.grid.itemForTesting(h.id(long)))
        let onName = NSPoint(x: item.view.frame.midX, y: item.view.frame.maxY + open.overflow - 4)
        let under = h.grid.collectionForTesting.visibleItems().first { $0 !== item && $0.view.frame.contains(onName) }
        XCTAssertNotNil(under, "the point isn't over the item under the name")
        h.click(at: onName)
        XCTAssertEqual(h.grid.collectionForTesting.selectionIndexPaths, Set([h.path(long)].compactMap { $0 }), "the click went to the item under the name")
        h.click(at: onName, count: 2)
        XCTAssertEqual(h.host.opened.last?.map(\.name), [long])
    }

    /// A drag over the part of a whole name past its item is over that item, as a click there is, so a file dropped
    /// on a selected folder's name goes into that folder, not into the one under the name.
    func testADragOverTheWholeNameIsOverItsItem() throws {
        let folders = [file(long, .directory)] + (1...7).map { file("zz-folder-\($0)", .directory) }
        let h = GridNamesHarness(tab: loadedTab(folders), context: context)
        h.select(long)
        let open = try XCTUnwrap(h.report(long))
        XCTAssertGreaterThan(open.overflow, 0)
        let item = try XCTUnwrap(h.grid.itemForTesting(h.id(long)))
        let frame = item.view.frame
        let layout = h.grid.layoutForTesting
        let onName = layout.layoutAttributesForDropTarget(at: NSPoint(x: frame.midX, y: frame.maxY + open.overflow - 4))
        XCTAssertEqual(onName?.indexPath, h.path(long))
        XCTAssertEqual(onName?.representedElementCategory, .item)
        // Below the name, the folder under it takes the drop, as before.
        let below = layout.layoutAttributesForDropTarget(at: NSPoint(x: frame.midX, y: frame.maxY + open.overflow + 30))
        XCTAssertNotNil(below?.indexPath)
        XCTAssertNotEqual(below?.indexPath, h.path(long))
    }

    /// Scrolling thousands of items works each name out once; scrolling back finds them all.
    func testScrollingThousandsOfItemsWorksEachNameOutOnce() throws {
        let tag = UUID().uuidString.prefix(8)
        let names = (0..<2_000).map { "\(tag) quarterly report \($0) for the finance team, reviewed and final \($0 * 3).pdf" }
        let h = harness(names)
        let clip = try XCTUnwrap((h.grid.view as? NSScrollView)?.contentView)
        let before = GridNameCache.shared.computed
        func scrollThrough() {
            let height = h.grid.collectionForTesting.frame.height
            var y: CGFloat = 0
            while y < height {
                clip.scroll(to: NSPoint(x: 0, y: y))
                h.grid.collectionForTesting.layoutSubtreeIfNeeded()
                y += clip.bounds.height
            }
        }
        let start = Date()
        scrollThrough()
        let first = GridNameCache.shared.computed - before
        XCTAssertGreaterThan(first, 100)
        XCTAssertLessThanOrEqual(first, names.count, "a name was worked out more than once")
        clip.scroll(to: .zero)
        scrollThrough()
        XCTAssertEqual(GridNameCache.shared.computed - before, first, "scrolling back worked names out again")
        XCTAssertLessThan(Date().timeIntervalSince(start), 30)
    }

    // MARK: The list

    /// The list stays as it was: one line, the whole name when the Name column has room for it, and a cut in the
    /// middle only when the column is too narrow. Helm never shortens the words itself.
    func testTheListCutsOnlyWhenTheNameColumnIsTooNarrow() throws {
        ListMotion.enabled = false
        addTeardownBlock { @MainActor in ListMotion.enabled = true }
        let name = "Quarterly report final version.pdf"
        let h = HuntViewsListHarness(tab: loadedTab([file(name), file("notes.txt"), file(long)]), context: context)
        let id = ItemID(url: root.appendingPathComponent(name))
        let wide = try XCTUnwrap(h.list.nameFitForTesting(id))
        XCTAssertEqual(wide.words, name)
        XCTAssertTrue(wide.fitsWhole, "a name the column has room for is shown whole, at \(wide.columnWidth) points")
        XCTAssertEqual(wide.lines, 1)
        XCTAssertTrue(wide.cutsInMiddle)
        // The column made narrow: the same words, cut in the middle, still on one line.
        h.outline.tableColumns[0].width = 140
        h.window.layoutIfNeeded()
        let narrow = try XCTUnwrap(h.list.nameFitForTesting(id))
        XCTAssertEqual(narrow.words, name)
        XCTAssertFalse(narrow.fitsWhole)
        XCTAssertEqual(narrow.lines, 1)
        XCTAssertTrue(narrow.cutsInMiddle)
        // A short name still fits whole in the narrow column, and nothing else is cut.
        let short = try XCTUnwrap(h.list.nameFitForTesting(ItemID(url: root.appendingPathComponent("notes.txt"))))
        XCTAssertTrue(short.fitsWhole)
        XCTAssertEqual(short.words, "notes.txt")
        // The long name keeps all its words in the cell, for AppKit to cut on show.
        let longFit = try XCTUnwrap(h.list.nameFitForTesting(ItemID(url: root.appendingPathComponent(long))))
        XCTAssertEqual(longFit.words, long)
        XCTAssertEqual(longFit.lines, 1)
    }
}

/// A grid in an offscreen window; each action goes to the reducer and the result is rendered straight back.
@MainActor final class GridNamesHarness {
    let grid = FileGridController()
    let host = HuntViewsHost()
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
    var tab: TabState
    let context: ReducerContext
    init(tab: TabState, context: ReducerContext) {
        self.tab = tab; self.context = context
        grid.host = host
        window.contentView = grid.view
        grid.render(tab, force: true)
        window.layoutIfNeeded()
    }
    func send(_ action: TabAction) {
        tab = TabReducer.reduce(tab, action, context: context).0
        grid.render(tab, force: false)
        window.layoutIfNeeded()
    }
    /// Selects these, as a click or Shift-click does.
    func select(_ names: String...) {
        send(.setSelection(Set(names.map(id)), source: .user))
    }
    func id(_ name: String) -> ItemID {
        tab.snapshot.sortedEntries.first { $0.name == name }?.id ?? ItemID(url: URL(fileURLWithPath: "/missing"))
    }
    func path(_ name: String) -> IndexPath? {
        guard let item = grid.itemForTesting(id(name)) else { return nil }
        return grid.collectionForTesting.indexPath(for: item)
    }
    func report(_ name: String) -> GridNameReport? { grid.nameReportForTesting(id(name)) }
    /// Clicks at `point`, in the grid's coordinates, as the window delivers a click: to the view under the pointer,
    /// which passes it up to the grid. The mouse-up waits in the queue for the grid's own tracking to take it.
    func click(at point: NSPoint, count: Int = 1) {
        let inWindow = grid.collectionForTesting.convert(point, to: nil)
        let stamp = ProcessInfo.processInfo.systemUptime
        guard let app = Optional(NSApplication.shared), let content = window.contentView,
              let down = NSEvent.mouseEvent(with: .leftMouseDown, location: inWindow, modifierFlags: [], timestamp: stamp,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: count, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: inWindow, modifierFlags: [], timestamp: stamp + 0.01,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: count, pressure: 0)
        else { return XCTFail("no click") }
        app.postEvent(up, atStart: false)
        let hit = content.hitTest(content.superview?.convert(inWindow, from: nil) ?? inWindow)
        hit?.mouseDown(with: down)
        if let left = app.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { hit?.mouseUp(with: left) }
    }
    var font: NSFont { .systemFont(ofSize: host.fileTextSize) }
    var lineHeight: CGFloat { GridNameMetrics.lineHeight(for: font) }
    var metrics: GridItemMetrics { GridItemMetrics(iconSize: CGFloat(host.gridIconSize), lineHeight: lineHeight) }
}
#endif
