// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

/// Clipboard facts for F-051; adapters must invalidate stale internal cuts (B-036).
public enum CommandClipboardState: Sendable { case empty, text, files, cutFiles }
/// Pure menu state fixes missing validation (B-075); text commands still route to NSText first.
public enum CommandAvailability: Sendable { case enabled, disabled, hidden }
/// Stable validation IDs allow platform adapters to share pure policy (B-031, B-118).
public enum CommandValidationRule: String, Sendable {
    case application, window, selection, singleSelection, mutationSelection, destination
    case clipboard, textOrSelection, selectAll, rename, quickLook, undo, redo
    case back, forward, up, location, trashSelection, trashLocation, recentLocation, directory, planned
}

/// Snapshot-only facts preserve F-051/F-055 and prevent B-031/B-118 without filesystem access.
/// Text availability means delegate to the text responder, which validates its own selection/pasteboard.
public struct CommandContext: Sendable {
    public var selectionCount: Int
    public var hasMutationTarget: Bool
    public var locationKind: LocationKind
    public var clipboard: CommandClipboardState
    public var textFieldFocused: Bool
    public var searchOverlayActive: Bool
    public var canUndo: Bool
    public var canRedo: Bool
    public var paneFocused: Bool
    public var typeSelectActive: Bool
    public var hasWindow: Bool
    public var canGoBack: Bool
    public var canGoForward: Bool
    public var canGoUp: Bool
    public init(selectionCount: Int = 0, hasMutationTarget: Bool = false,
                locationKind: LocationKind = .directory, clipboard: CommandClipboardState = .empty,
                textFieldFocused: Bool = false, searchOverlayActive: Bool = false,
                canUndo: Bool = false, canRedo: Bool = false, paneFocused: Bool = true,
                typeSelectActive: Bool = false, hasWindow: Bool = true,
                canGoBack: Bool = false, canGoForward: Bool = false, canGoUp: Bool = false) {
        self.selectionCount = max(0, selectionCount); self.hasMutationTarget = hasMutationTarget
        self.locationKind = locationKind; self.clipboard = clipboard
        self.textFieldFocused = textFieldFocused; self.searchOverlayActive = searchOverlayActive
        self.canUndo = canUndo; self.canRedo = canRedo; self.paneFocused = paneFocused
        self.typeSelectActive = typeSelectActive; self.hasWindow = hasWindow
        self.canGoBack = canGoBack; self.canGoForward = canGoForward; self.canGoUp = canGoUp
    }
}

/// Exhaustive menu policy preserves multi-rename (F-055) and text-first editing (F-051).
public enum CommandValidation {
    public static func rule(for command: CommandID) -> CommandValidationRule {
        switch command {
        case .about, .settings, .advancedOptions, .services, .hide, .hideOthers, .showAll, .quit,
             .newWindow, .bringAllToFront, .help: return .application
        case .newTab, .find, .closeTab, .grid, .list, .sidebar, .hidden, .refresh, .home,
             .minimize, .zoom: return .window
        case .open, .share, .star: return .selection
        case .openWith, .properties: return .singleSelection
        case .trash, .permanentDelete, .duplicate: return .mutationSelection
        case .newFolder, .newFile, .newTextFile, .newFromTemplate: return .destination
        case .cut, .copy: return .textOrSelection
        case .paste: return .clipboard
        case .selectAll: return .selectAll
        case .rename: return .rename
        case .quickLook: return .quickLook
        case .undo: return .undo
        case .redo: return .redo
        case .back: return .back
        case .forward: return .forward
        case .up: return .up
        case .location: return .location
        case .putBack: return .trashSelection
        case .emptyTrash: return .trashLocation
        case .clearRecent: return .recentLocation
        case .directoryProperties, .removeBookmark, .copyPath: return .directory
        case .openInNewTab, .openInNewWindow, .closeWindow, .reopenClosedTab, .nextTab,
             .previousTab, .makeAlias, .makeSymbolicLink, .eject, .reveal, .showOriginal,
             .connectToServer, .newFolderWithSelection, .addToSidebar, .copyAsPathname,
             .moveItemsHere, .printSelection, .columns, .gallery, .previewPane, .viewOptions,
             .desktop, .documents, .downloads, .applications, .utilities, .computer,
             .network, .compress, .decompress, .tags: return .planned
        }
    }

    public static func state(for command: CommandID, in context: CommandContext) -> CommandAvailability {
        let rule = rule(for: command)
        if rule == .planned { return .disabled }
        if rule == .application { return .enabled }
        guard context.hasWindow else { return .disabled }
        let selection = context.selectionCount > 0 && !context.textFieldFocused
        let destination = context.hasMutationTarget && context.locationKind == .directory && !context.searchOverlayActive
        let mutation = selection && destination
        let enabled: Bool
        switch rule {
        case .application: enabled = true
        case .window: enabled = true
        case .selection: enabled = selection
        case .singleSelection:
            enabled = (selection && context.selectionCount == 1) ||
                (command == .properties && context.selectionCount == 0 && destination && !context.textFieldFocused)
        case .mutationSelection: enabled = mutation
        case .destination: enabled = destination && !context.textFieldFocused
        case .textOrSelection:
            enabled = context.textFieldFocused || (command == .cut ? mutation : selection)
        case .clipboard:
            enabled = context.textFieldFocused || (destination && (context.clipboard == .files || context.clipboard == .cutFiles))
        case .selectAll: enabled = context.textFieldFocused || context.paneFocused
        case .rename: enabled = mutation && context.paneFocused
        case .quickLook: enabled = selection && context.paneFocused && !context.typeSelectActive
        case .undo: enabled = context.textFieldFocused || context.canUndo
        case .redo: enabled = context.textFieldFocused || context.canRedo
        case .back: enabled = context.canGoBack
        case .forward: enabled = context.canGoForward
        case .up: enabled = context.canGoUp && context.locationKind == .directory
        case .location: enabled = !context.textFieldFocused
        case .trashSelection:
            guard context.locationKind == .trash else { return .hidden }
            enabled = selection
        case .trashLocation:
            guard context.locationKind == .trash else { return .hidden }
            enabled = !context.textFieldFocused
        case .recentLocation:
            guard context.locationKind == .recent else { return .hidden }
            enabled = !context.textFieldFocused
        case .directory: enabled = destination && !context.textFieldFocused
        case .planned: enabled = false
        }
        // Trash selection has no ordinary mutation target, but permanent deletion is explicit.
        if command == .permanentDelete && context.locationKind == .trash { return selection ? .enabled : .disabled }
        return enabled ? .enabled : .disabled
    }
}
