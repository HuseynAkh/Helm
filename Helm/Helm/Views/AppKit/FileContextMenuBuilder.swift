import Cocoa
import UniformTypeIdentifiers

/// Builds context menus for file items and directory background
@MainActor
class FileContextMenuBuilder {

    weak var delegate: FileContextMenuDelegate?

    /// Build context menu for selected file items
    func buildMenu(for items: [FileItem], in directoryURL: URL) -> NSMenu {
        let menu = NSMenu()

        if items.isEmpty {
            // Background context menu (right-click on empty area)
            return buildBackgroundMenu(for: directoryURL)
        }

        let singleItem = items.count == 1 ? items.first : nil

        // Open
        if let singleItem {
            let openItem = NSMenuItem(title: "Open", action: #selector(FileContextMenuDelegate.contextMenuOpen(_:)), keyEquivalent: "")
            openItem.target = delegate
            openItem.representedObject = singleItem
            menu.addItem(openItem)

            // Open With submenu
            let openWithItem = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
            openWithItem.submenu = buildOpenWithSubmenu(for: singleItem)
            menu.addItem(openWithItem)
        } else {
            let openItem = NSMenuItem(title: "Open \(items.count) Items", action: #selector(FileContextMenuDelegate.contextMenuOpenMultiple(_:)), keyEquivalent: "")
            openItem.target = delegate
            openItem.representedObject = items
            menu.addItem(openItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Cut / Copy / Paste
        let cutItem = NSMenuItem(title: "Cut", action: #selector(FileContextMenuDelegate.contextMenuCut(_:)), keyEquivalent: "x")
        cutItem.target = delegate
        cutItem.representedObject = items
        menu.addItem(cutItem)

        let copyItem = NSMenuItem(title: "Copy", action: #selector(FileContextMenuDelegate.contextMenuCopy(_:)), keyEquivalent: "c")
        copyItem.target = delegate
        copyItem.representedObject = items
        menu.addItem(copyItem)

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(FileContextMenuDelegate.contextMenuPaste(_:)), keyEquivalent: "v")
        pasteItem.target = delegate
        pasteItem.representedObject = directoryURL
        pasteItem.isEnabled = NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)
        menu.addItem(pasteItem)

        menu.addItem(NSMenuItem.separator())

        // Star / Unstar
        if let singleItem {
            let starTitle = singleItem.isStarred ? "Remove from Starred" : "Star"
            let starItem = NSMenuItem(title: starTitle, action: #selector(FileContextMenuDelegate.contextMenuToggleStar(_:)), keyEquivalent: "d")
            starItem.target = delegate
            starItem.representedObject = singleItem
            menu.addItem(starItem)

            menu.addItem(NSMenuItem.separator())
        }

        // Rename
        if items.count == 1 {
            let renameItem = NSMenuItem(title: "Rename", action: #selector(FileContextMenuDelegate.contextMenuRename(_:)), keyEquivalent: "\r")
            renameItem.keyEquivalentModifierMask = []
            renameItem.target = delegate
            renameItem.representedObject = singleItem
            menu.addItem(renameItem)
        } else if items.count > 1 {
            // Batch rename
            let batchRenameItem = NSMenuItem(title: "Rename \(items.count) Items...", action: #selector(FileContextMenuDelegate.contextMenuBatchRename(_:)), keyEquivalent: "")
            batchRenameItem.target = delegate
            batchRenameItem.representedObject = items
            menu.addItem(batchRenameItem)
        }

        // Move to Trash
        let trashItem = NSMenuItem(title: "Move to Trash", action: #selector(FileContextMenuDelegate.contextMenuTrash(_:)), keyEquivalent: "\u{8}") // backspace
        trashItem.keyEquivalentModifierMask = [.command]
        trashItem.target = delegate
        trashItem.representedObject = items
        menu.addItem(trashItem)

        menu.addItem(NSMenuItem.separator())

        // Properties
        if let singleItem {
            let propertiesItem = NSMenuItem(title: "Properties", action: #selector(FileContextMenuDelegate.contextMenuProperties(_:)), keyEquivalent: "i")
            propertiesItem.target = delegate
            propertiesItem.representedObject = singleItem
            menu.addItem(propertiesItem)
        }

        // Share
        let shareItem = NSMenuItem(title: "Share", action: nil, keyEquivalent: "")
        shareItem.submenu = buildShareSubmenu(for: items)
        menu.addItem(shareItem)

        return menu
    }

    /// Build context menu for right-click on empty background
    private func buildBackgroundMenu(for directoryURL: URL) -> NSMenu {
        let menu = NSMenu()

        // Paste
        let pasteItem = NSMenuItem(title: "Paste", action: #selector(FileContextMenuDelegate.contextMenuPaste(_:)), keyEquivalent: "v")
        pasteItem.target = delegate
        pasteItem.representedObject = directoryURL
        pasteItem.isEnabled = NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)
        menu.addItem(pasteItem)

        menu.addItem(NSMenuItem.separator())

        // New Folder
        let newFolderItem = NSMenuItem(title: "New Folder", action: #selector(FileContextMenuDelegate.contextMenuNewFolder(_:)), keyEquivalent: "N")
        newFolderItem.keyEquivalentModifierMask = [.command, .shift]
        newFolderItem.target = delegate
        newFolderItem.representedObject = directoryURL
        menu.addItem(newFolderItem)

        // New File
        let newFileItem = NSMenuItem(title: "New File", action: nil, keyEquivalent: "")
        newFileItem.submenu = buildNewFileSubmenu(in: directoryURL)
        menu.addItem(newFileItem)

        menu.addItem(NSMenuItem.separator())

        // Properties of directory
        let propertiesItem = NSMenuItem(title: "Properties", action: #selector(FileContextMenuDelegate.contextMenuDirectoryProperties(_:)), keyEquivalent: "")
        propertiesItem.target = delegate
        propertiesItem.representedObject = directoryURL
        menu.addItem(propertiesItem)

        return menu
    }

    // MARK: - Submenus

    private func buildOpenWithSubmenu(for item: FileItem) -> NSMenu {
        let submenu = NSMenu()
        let appURLs = NSWorkspace.shared.urlsForApplications(toOpen: item.url)

        for appURL in appURLs.prefix(10) {
            let appName = appURL.deletingPathExtension().lastPathComponent
            let menuItem = NSMenuItem(title: appName, action: #selector(FileContextMenuDelegate.contextMenuOpenWith(_:)), keyEquivalent: "")
            menuItem.target = delegate
            menuItem.representedObject = (item.url, appURL)
            menuItem.image = NSWorkspace.shared.icon(forFile: appURL.path)
            menuItem.image?.size = NSSize(width: 16, height: 16)
            submenu.addItem(menuItem)
        }

        if submenu.items.isEmpty {
            let noneItem = NSMenuItem(title: "No Applications", action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            submenu.addItem(noneItem)
        }

        return submenu
    }

    private func buildShareSubmenu(for items: [FileItem]) -> NSMenu {
        let submenu = NSMenu()
        let urls = items.map(\.url)
        let services = NSSharingService.sharingServices(forItems: urls)

        for service in services {
            let menuItem = NSMenuItem(title: service.title, action: #selector(FileContextMenuDelegate.contextMenuShare(_:)), keyEquivalent: "")
            menuItem.target = delegate
            menuItem.representedObject = (service, urls)
            menuItem.image = service.image
            menuItem.image?.size = NSSize(width: 16, height: 16)
            submenu.addItem(menuItem)
        }

        if submenu.items.isEmpty {
            let noneItem = NSMenuItem(title: "No Sharing Options", action: nil, keyEquivalent: "")
            noneItem.isEnabled = false
            submenu.addItem(noneItem)
        }

        return submenu
    }

    private func buildNewFileSubmenu(in directoryURL: URL) -> NSMenu {
        let submenu = NSMenu()

        // Check ~/Templates/ for user templates
        let templatesURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Templates")
        if FileManager.default.fileExists(atPath: templatesURL.path) {
            if let templates = try? FileManager.default.contentsOfDirectory(
                at: templatesURL,
                includingPropertiesForKeys: [.isHiddenKey],
                options: [.skipsHiddenFiles]
            ), !templates.isEmpty {
                for template in templates {
                    let item = NSMenuItem(
                        title: template.lastPathComponent,
                        action: #selector(FileContextMenuDelegate.contextMenuNewFromTemplate(_:)),
                        keyEquivalent: ""
                    )
                    item.target = delegate
                    item.representedObject = (template, directoryURL)
                    item.image = NSWorkspace.shared.icon(forFile: template.path)
                    item.image?.size = NSSize(width: 16, height: 16)
                    submenu.addItem(item)
                }
                submenu.addItem(NSMenuItem.separator())
            }
        }

        // Default file types
        let textFileItem = NSMenuItem(title: "Empty Text File", action: #selector(FileContextMenuDelegate.contextMenuNewTextFile(_:)), keyEquivalent: "")
        textFileItem.target = delegate
        textFileItem.representedObject = directoryURL
        submenu.addItem(textFileItem)

        return submenu
    }
}

// MARK: - Delegate Protocol

@MainActor
@objc protocol FileContextMenuDelegate: AnyObject {
    func contextMenuOpen(_ sender: NSMenuItem)
    func contextMenuOpenMultiple(_ sender: NSMenuItem)
    func contextMenuOpenWith(_ sender: NSMenuItem)
    func contextMenuCut(_ sender: NSMenuItem)
    func contextMenuCopy(_ sender: NSMenuItem)
    func contextMenuPaste(_ sender: NSMenuItem)
    func contextMenuToggleStar(_ sender: NSMenuItem)
    func contextMenuRename(_ sender: NSMenuItem)
    func contextMenuBatchRename(_ sender: NSMenuItem)
    func contextMenuTrash(_ sender: NSMenuItem)
    func contextMenuProperties(_ sender: NSMenuItem)
    func contextMenuDirectoryProperties(_ sender: NSMenuItem)
    func contextMenuShare(_ sender: NSMenuItem)
    func contextMenuNewFolder(_ sender: NSMenuItem)
    func contextMenuNewFromTemplate(_ sender: NSMenuItem)
    func contextMenuNewTextFile(_ sender: NSMenuItem)
}
