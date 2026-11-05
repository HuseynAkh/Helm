// DRAFT: pending Opus review after 22:00 Toronto, 2026-11-04

/// File/folder share the legacy action order; virtual locations supply explicit actions (F-038, B-031).
public enum CommandMenuContext: Sendable { case file, folder, background, multiple, trash, recent }

/// Pure action tables preserve FileContextMenuBuilder.swift:12–144 (F-051–F-057, F-062–F-063).
/// Open With, Share and New File are dynamic submenu slots, populated by the macOS adapter.
public enum ContextMenuModel {
    public static func menu(for kind: CommandMenuContext, selectionCount: Int = 1,
                            isStarred: Bool = false, includeAdditions: Bool = true) -> MenuModel {
        let count = max(0, selectionCount)
        let background = kind == .background || count == 0
        let item = MenuModel.item
        var sections: [[CommandMenuItem]]
        if background {
            sections = [[item("Paste", .paste, "v", .command, false)],
                [item("New Folder", .newFolder, "N", [.command, .shift], false), item("New File", .newFile, nil, .command, false)],
                [item("Properties", .directoryProperties, nil, .command, false)]]
        } else {
            sections = [[item(count == 1 ? "Open" : "Open \(count) Items", .open, nil, .command, false)]]
            if count == 1 { sections[0].append(item("Open With", .openWith, nil, .command, false)) }
            sections.append([item("Cut", .cut, "x", .command, false), item("Copy", .copy, "c", .command, false), item("Paste", .paste, "v", .command, false)])
            if count == 1 { sections.append([item(isStarred ? "Remove from Starred" : "Star", .star, "d", .command, false)]) }
            sections.append([item(count == 1 ? "Rename" : "Rename \(count) Items...", .rename, count == 1 ? "\r" : nil, [], false),
                item("Move to Trash", .trash, "\u{8}", .command, false)])
            var last: [CommandMenuItem] = []
            if count == 1 { last.append(item("Properties", .properties, "i", .command, false)) }
            last.append(item("Share", .share, nil, .command, false))
            sections.append(last)
        }
        if includeAdditions {
            if !background {
                sections[0] += [item("Open in New Tab", .openInNewTab, nil, .command, true), item("Open in New Window", .openInNewWindow, nil, .command, true)]
                sections.append([item("Duplicate", .duplicate, nil, .command, true), item("Make Alias", .makeAlias, nil, .command, true),
                    item("Quick Look", .quickLook, nil, [], true), item("Show in Enclosing Folder", .reveal, nil, .command, true)])
            }
            if kind == .trash {
                if !background { sections.append([item("Put Back", .putBack, nil, .command, true), item("Delete Immediately...", .permanentDelete, nil, .command, true)]) }
                sections.append([item("Empty Trash...", .emptyTrash, nil, .command, true)])
            }
            if kind == .recent { sections.append([item("Clear Recent", .clearRecent, nil, .command, true)]) }
        }
        return MenuModel(title: "", sections: sections)
    }

    /// Templates remain adapter-supplied in enumeration order, including directories (F-057).
    public static let newFileFallback = CommandMenuItem(title: "Empty Text File", command: .newTextFile)
}
