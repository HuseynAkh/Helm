// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

/// Stable action identities preserve F-049–F-066 and the menu map in main.swift:19–142.
/// Planned cases describe data only; they do not authorize or execute operations.
public enum CommandID: String, CaseIterable, Codable, Sendable {
    case about, settings, advancedOptions, services, hide, hideOthers, showAll, quit
    case newWindow, newTab, newFolder, find, closeTab
    case undo, redo, cut, copy, paste, selectAll, rename, trash, properties
    case grid, list, sidebar, hidden, refresh, back, forward, up, home, location, star
    case minimize, zoom, bringAllToFront, help, quickLook
    case open, openWith, share, newFile, newTextFile, newFromTemplate, directoryProperties
    case removeBookmark, copyPath
    // Rebuild additions (architecture 8.3).
    case permanentDelete, emptyTrash, clearRecent, putBack, duplicate
    // Finder parity (14.5). `isPlanned` marks the ones still disabled.
    case openInNewTab, openInNewWindow, closeWindow, reopenClosedTab, nextTab, previousTab
    case makeAlias, makeSymbolicLink, eject, reveal, showOriginal, connectToServer
    case newFolderWithSelection, addToSidebar, copyAsPathname, moveItemsHere, printSelection
    case columns, gallery, previewPane, viewOptions, desktop, documents, downloads, recents
    case applications, utilities, computer, network, compress, decompress, tags

    /// Still later, per OWNER_RULINGS.md. Everything else in the menus works.
    public var isPlanned: Bool {
        switch self {
        case .printSelection, .columns, .gallery, .previewPane, .viewOptions, .computer, .network,
             .compress, .decompress, .tags: return true
        default: return false
        }
    }
}
