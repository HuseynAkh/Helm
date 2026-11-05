// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

/// Declarative menu item preserves legacy labels and routing (F-066); children are dynamic adapter slots.
public struct CommandMenuItem: Equatable, Sendable {
    public let title: String
    public let command: CommandID
    public let binding: KeyBinding?
    public let validationRuleID: CommandValidationRule
    public let isNew: Bool
    public init(title: String, command: CommandID, binding: KeyBinding? = nil, isNew: Bool = false) {
        self.title = title; self.command = command; self.binding = binding
        self.validationRuleID = CommandValidation.rule(for: command); self.isNew = isNew
    }
}

/// Sections render with one separator between each pair; empty sections preserve legacy separators (F-066).
public struct MenuModel: Equatable, Sendable {
    public let title: String
    public let sections: [[CommandMenuItem]]
    public init(title: String, sections: [[CommandMenuItem]]) { self.title = title; self.sections = sections }

    /// Exact main.swift:19–142 order, titles, key strings and explicit/default masks.
    /// In particular File's empty section preserves the double separator at lines 56–57.
    public static let legacy: [MenuModel] = [
        MenuModel(title: "Helm", sections: [
            [item("About Helm", .about)],
            [item("Settings...", .settings, ","), item("Advanced Options...", .advancedOptions)],
            [item("Services", .services)],
            [item("Hide Helm", .hide, "h"), item("Hide Others", .hideOthers, "h", [.command, .option]), item("Show All", .showAll)],
            [item("Quit Helm", .quit, "q")]]), // main.swift:19–43
        MenuModel(title: "File", sections: [
            [item("New Window", .newWindow, "n"), item("New Tab", .newTab, "t")],
            [item("New Folder", .newFolder, "N", [.command, .shift])], [],
            [item("Find...", .find, "f")], [item("Close Tab", .closeTab, "w")]]), // :50–60
        MenuModel(title: "Edit", sections: [
            [item("Undo", .undo, "z"), item("Redo", .redo, "z", [.command, .shift])],
            [item("Cut", .cut, "x"), item("Copy", .copy, "c"), item("Paste", .paste, "v"), item("Select All", .selectAll, "a")],
            [item("Rename", .rename, "\r", []), item("Move to Trash", .trash, "\u{8}")],
            [item("Properties", .properties, "i")]]), // :67–84
        MenuModel(title: "View", sections: [
            [item("as Grid", .grid, "1"), item("as List", .list, "2")],
            [item("Toggle Sidebar", .sidebar, "s", [.command, .control])],
            [item("Show Hidden Files", .hidden, ".")], [item("Refresh", .refresh, "r")]]), // :92–105
        MenuModel(title: "Go", sections: [
            [item("Back", .back, "["), item("Forward", .forward, "]"), item("Enclosing Folder", .up, "\u{f700}")],
            [item("Home", .home, "H")], [item("Go to Folder...", .location, "l")],
            [item("Toggle Star", .star, "d")]]), // :112–124
        MenuModel(title: "Window", sections: [
            [item("Minimize", .minimize, "m"), item("Zoom", .zoom)],
            [item("Bring All to Front", .bringAllToFront)]]), // :131–134
        MenuModel(title: "Help", sections: []) // :137–142
    ]

    /// New entries are explicit; existing entries keep their original positions relative to each other.
    /// Planned parity placeholders remain disabled; reserved tab shortcuts are never installed.
    public static let menuBar: [MenuModel] = legacy.map { menu in
        var sections = menu.sections
        switch menu.title {
        case "File":
            sections.insert([
                item("Open", .open, "o", isNew: true), item("Open With", .openWith, isNew: true),
                item("Open in New Tab", .openInNewTab, isNew: true), item("Open in New Window", .openInNewWindow, isNew: true),
                item("Quick Look", .quickLook, " ", [], isNew: true)], at: 3)
            sections.insert([
                item("Duplicate", .duplicate, isNew: true), item("Make Alias", .makeAlias, isNew: true),
                item("Make Symbolic Link", .makeSymbolicLink, isNew: true), item("Show Original", .showOriginal, isNew: true),
                item("Compress", .compress, isNew: true), item("Decompress", .decompress, isNew: true)], at: 4)
            sections.append([item("Put Back", .putBack, isNew: true), item("Delete Immediately...", .permanentDelete, "\u{8}", [.command, .option], isNew: true),
                item("Empty Trash...", .emptyTrash, "\u{8}", [.command, .shift], isNew: true),
                item("Eject", .eject, isNew: true), item("Share", .share, isNew: true), item("Tags...", .tags, isNew: true),
                item("Print...", .printSelection, isNew: true)])
            sections.append([item("New Folder with Selection", .newFolderWithSelection, isNew: true), item("Close Window", .closeWindow, isNew: true)])
        case "Edit":
            sections.append([item("Copy as Pathname", .copyAsPathname, isNew: true), item("Move Items Here", .moveItemsHere, isNew: true)])
        case "View":
            sections[0] += [item("as Columns", .columns, isNew: true), item("as Gallery", .gallery, isNew: true)]
            sections.append([item("Show Preview", .previewPane, isNew: true), item("Show View Options", .viewOptions, isNew: true)])
        case "Go":
            sections.append([item("Desktop", .desktop, isNew: true), item("Documents", .documents, isNew: true),
                item("Downloads", .downloads, isNew: true), item("Applications", .applications, isNew: true),
                item("Utilities", .utilities, isNew: true), item("Computer", .computer, isNew: true), item("Network", .network, isNew: true)])
            sections.append([item("Connect to Server...", .connectToServer, isNew: true), item("Clear Recent", .clearRecent, isNew: true),
                item("Show in Enclosing Folder", .reveal, isNew: true), item("Add to Sidebar", .addToSidebar, isNew: true)])
        case "Window":
            sections.append([item("Show Next Tab", .nextTab, isNew: true), item("Show Previous Tab", .previousTab, isNew: true), item("Reopen Closed Tab", .reopenClosedTab, isNew: true)])
        default: break
        }
        return MenuModel(title: menu.title, sections: sections)
    }

    public static var defaultBindings: [KeyBinding] {
        menuBar.flatMap(\.sections).flatMap { $0 }.compactMap(\.binding)
            + [KeyBinding(command: .open, key: "\u{f701}")]
    }

    static func item(_ title: String, _ command: CommandID, _ key: String? = nil,
                     _ modifiers: KeyModifiers = .command, isNew: Bool = false) -> CommandMenuItem {
        CommandMenuItem(title: title, command: command,
                        binding: key.map { KeyBinding(command: command, key: $0, modifiers: modifiers) }, isNew: isNew)
    }
}
