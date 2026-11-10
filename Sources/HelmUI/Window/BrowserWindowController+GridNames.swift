#if os(macOS)
import AppKit
import HelmCore

/// What the grid shows for one item's name, for tests and scripted runs, since nobody is there to look.
public struct GridNameReport: Equatable {
    /// The name as shown when it's whole: an app's without ".app".
    public let name: String
    /// The lines on show, top to bottom.
    public let lines: [String]
    /// How many lines the label really draws them on: the same number, unless one wrapped again.
    public let drawnLines: Int
    /// Whether part of the name was left out.
    public let isShortened: Bool
    /// Whether it's the one item selected, showing its whole name.
    public let isExpanded: Bool
    public let toolTip: String?
    /// What VoiceOver reads for the item, and for the words under its icon.
    public let spokenName: String?
    public let spokenWords: String?
    /// Whether the item is drawn over the items around it.
    public let isOnTop: Bool
    /// How far the name and its highlight run past the bottom of the item.
    public let overflow: CGFloat
    /// Whether the items and headings under the part of the name past the item cut that part away, so none of them
    /// shows through the name's highlight.
    public let coversBelow: Bool
    /// The words in the rename field while renaming, or nil.
    public let fieldWords: String?
    public init(name: String, lines: [String], drawnLines: Int, isShortened: Bool, isExpanded: Bool, toolTip: String?,
                spokenName: String?, spokenWords: String?, isOnTop: Bool, overflow: CGFloat, coversBelow: Bool, fieldWords: String?) {
        self.name = name; self.lines = lines; self.drawnLines = drawnLines
        self.isShortened = isShortened; self.isExpanded = isExpanded; self.toolTip = toolTip
        self.spokenName = spokenName; self.spokenWords = spokenWords; self.isOnTop = isOnTop
        self.overflow = overflow; self.coversBelow = coversBelow; self.fieldWords = fieldWords
    }
}

/// What the list's name cell shows for a file.
public struct ListNameFit: Equatable {
    public let words: String
    /// Whether the Name column is wide enough for all of them.
    public let fitsWhole: Bool
    public let lines: Int
    /// Whether a name too long for the column is cut in the middle, on its one line.
    public let cutsInMiddle: Bool
    public let columnWidth: CGFloat
    public init(words: String, fitsWhole: Bool, lines: Int, cutsInMiddle: Bool, columnWidth: CGFloat) {
        self.words = words; self.fitsWhole = fitsWhole; self.lines = lines
        self.cutsInMiddle = cutsInMiddle; self.columnWidth = columnWidth
    }
}

/// Scripted runs read and set the names on show through these.
extension BrowserWindowController {
    private var shownGrid: FileGridController? { shownContent as? FileGridController }
    private var shownNameList: FileListController? { shownContent as? FileListController }

    /// What the grid shows for the top-level item with this file name, or nil while the grid isn't on show.
    public func gridNameForTesting(_ fileName: String) -> GridNameReport? {
        guard let grid = shownGrid, let id = topLevelID(named: fileName) else { return nil }
        return grid.nameReportForTesting(id)
    }
    /// What the list's name cell shows for the top-level item with this file name, or nil while the list isn't on show.
    public func listNameForTesting(_ fileName: String) -> ListNameFit? {
        guard let list = shownNameList, let id = topLevelID(named: fileName) else { return nil }
        return list.nameFitForTesting(id)
    }
    /// Sets the list's Name column to `width` points, as dragging its edge does. False while the list isn't on show.
    public func setListNameWidthForTesting(_ width: CGFloat) -> Bool {
        guard let column = shownNameList?.outlineForTesting.tableColumns.first else { return false }
        column.width = width
        shownNameList?.outlineForTesting.layoutSubtreeIfNeeded()
        return abs(column.width - width) < 1
    }
    private func topLevelID(named name: String) -> ItemID? {
        guard let tab = activeTab else { return nil }
        return tab.snapshot.sortedEntries.prefix(tab.snapshot.rootCount).first { $0.name == name }?.id
    }
}
#endif
