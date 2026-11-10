#if os(macOS)
import AppKit
import HelmCore

/// Scripted runs read the list and grid through these, since nobody is there to look.
extension BrowserWindowController {
    private var shownList: FileListController? { shownContent as? FileListController }

    /// The list's rows, top to bottom, without headings or Loading rows. Empty while the grid is on show.
    public var listRowNamesForTesting: [String] { shownList?.rowNamesForTesting ?? [] }
    /// The rows the list itself shows selected.
    public var listSelectedNamesForTesting: [String] { shownList?.selectedRowNamesForTesting ?? [] }
    /// How many times the list was rebuilt whole. Opening and closing folders never adds to it.
    public var listReloadsForTesting: Int { shownList?.fullReloads ?? 0 }
    /// Whether the list shows the folder with this name open, or nil if no row has that name.
    public func listIsOpenForTesting(_ name: String) -> Bool? {
        guard let list = shownList, let id = visibleID(named: name) else { return nil }
        return list.isOpenForTesting(id)
    }
    /// Clicks the disclosure triangle of the visible row with this name, through AppKit's own click path.
    public func discloseInListForTesting(_ name: String) -> Bool {
        guard let list = shownList, let id = visibleID(named: name) else { return false }
        return list.discloseForTesting(id)
    }
    /// The list's row view for the visible row with this name, if it has one now, to watch it move.
    public func listRowViewForTesting(_ name: String) -> NSView? {
        guard let list = shownList, let id = visibleID(named: name) else { return nil }
        return list.rowViewForTesting(id)
    }
    /// Whether the folder with this name shows its Loading row.
    public func listShowsLoadingRowForTesting(_ name: String) -> Bool {
        guard let list = shownList, let id = visibleID(named: name) else { return false }
        return list.showsLoadingRowForTesting(id)
    }
    /// Holds back every folder listing opened in the list by this long, so a scripted run can see what a slow disk
    /// or share looks like. Zero, the default, adds nothing.
    public static var childListingDelayForTesting: TimeInterval {
        get { HostEffectRunner.childListingDelayForTesting }
        set { HostEffectRunner.childListingDelayForTesting = newValue }
    }
    /// Each heading on show with its number of items, such as "Folders 2"; empty without headings.
    public func contentSectionsForTesting() -> [String] { shownContent?.sectionSummaryForTesting ?? [] }
    /// Presses an arrow key ("up", "down", "left" or "right") in the files, as the keyboard does.
    public func contentKeyForTesting(_ key: String) -> Bool {
        let keys: [String: (code: UInt16, character: Int)] = [
            "left": (123, NSLeftArrowFunctionKey), "right": (124, NSRightArrowFunctionKey),
            "down": (125, NSDownArrowFunctionKey), "up": (126, NSUpArrowFunctionKey)]
        guard let (code, character) = keys[key], let scalar = UnicodeScalar(UInt32(character)),
              let window, let responder = shownContent?.keyResponder else { return false }
        let text = String(Character(scalar))
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                           context: nil, characters: text, charactersIgnoringModifiers: text,
                                           isARepeat: false, keyCode: code) else { return false }
        window.makeFirstResponder(responder)
        responder.keyDown(with: event)
        return true
    }
    /// The first row on show with this name, in the order the list shows them.
    private func visibleID(named name: String) -> ItemID? {
        guard let tab = activeTab else { return nil }
        return tab.snapshot.visibleIDs(expanding: tab.expandedIDs).first { tab.snapshot.entry($0)?.name == name }
    }
}
#endif
