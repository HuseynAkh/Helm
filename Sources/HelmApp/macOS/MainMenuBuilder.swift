#if os(macOS)
import AppKit
import HelmCore
import HelmUI

/// Builds the menu bar from Core's table, so titles, order and keys stay in one tested place (F-066).
/// Commands reach the key window through the responder chain; a focused text field answers Cut, Copy, Paste and Undo first.
@MainActor enum MainMenuBuilder {
    static func install(target: AppController) {
        let bar = NSMenu()
        for model in MenuModel.menuBar {
            let top = NSMenuItem(title: model.title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: model.title)
            menu.autoenablesItems = true
            for (index, section) in model.sections.enumerated() {
                if index > 0, !section.isEmpty || index == model.sections.count - 1, !menu.items.isEmpty, menu.items.last?.isSeparatorItem == false {
                    menu.addItem(.separator())
                }
                for row in section {
                    menu.addItem(item(for: row, target: target))
                }
            }
            if model.title == "Help", menu.items.isEmpty {
                menu.addItem(withTitle: "Helm Help", action: #selector(NSApplication.showHelp(_:)), keyEquivalent: "?")
            }
            if model.title == "Go" { addAliases(to: menu) }
            if model.title == "View" { addViewAliases(to: menu) }
            if model.title == "Window" { addTabAliases(to: menu) }
            if model.title == "File" { addQuickLookAlias(to: menu) }
            top.submenu = menu
            bar.addItem(top)
            if model.title == "Window" { NSApp.windowsMenu = menu }
            if model.title == "Help" { NSApp.helpMenu = menu }
        }
        NSApp.mainMenu = bar
    }

    private static func item(for row: CommandMenuItem, target: AppController) -> NSMenuItem {
        let item = NSMenuItem(title: row.title, action: action(for: row.command), keyEquivalent: row.binding?.key ?? "")
        item.keyEquivalentModifierMask = modifiers(row.binding?.modifiers ?? [])
        item.representedObject = row.command.rawValue
        switch row.command {
        case .about, .settings, .advancedOptions, .quit, .hide, .hideOthers, .showAll, .bringAllToFront, .newWindow:
            item.target = target
        case .services:
            let submenu = NSMenu(title: "Services")
            item.submenu = submenu
            NSApp.servicesMenu = submenu
            item.action = nil
        default: break
        }
        return item
    }

    private static func action(for command: CommandID) -> Selector {
        switch command {
        case .about: return #selector(AppController.orderFrontAbout(_:))
        case .settings, .advancedOptions: return #selector(AppController.showSettingsWindow(_:))
        case .quit: return #selector(AppController.quit(_:))
        case .hide: return #selector(NSApplication.hide(_:))
        case .hideOthers: return #selector(NSApplication.hideOtherApplications(_:))
        case .showAll: return #selector(NSApplication.unhideAllApplications(_:))
        case .bringAllToFront: return #selector(NSApplication.arrangeInFront(_:))
        case .newWindow: return #selector(AppController.newWindow(_:))
        case .cut: return #selector(NSText.cut(_:))
        case .copy: return #selector(NSText.copy(_:))
        case .paste: return #selector(NSText.paste(_:))
        case .selectAll: return #selector(NSText.selectAll(_:))
        case .undo: return #selector(BrowserWindowController.undo(_:))
        case .redo: return #selector(BrowserWindowController.redo(_:))
        default: return #selector(BrowserWindowController.helmCommand(_:))
        }
    }

    /// Extra keys for the location bar, hidden so each command still shows one shortcut: Nautilus's Ctrl+L and Finder's Shift+Cmd+G.
    private static func addAliases(to menu: NSMenu) {
        for (key, flags) in [("l", NSEvent.ModifierFlags.control), ("g", [.command, .shift])] {
            let item = NSMenuItem(title: "Go to Folder…", action: #selector(BrowserWindowController.helmCommand(_:)), keyEquivalent: key)
            item.keyEquivalentModifierMask = flags
            item.representedObject = CommandID.location.rawValue
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
            menu.addItem(item)
        }
    }

    private static func hidden(_ title: String, _ command: CommandID, _ key: String, _ flags: NSEvent.ModifierFlags) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(BrowserWindowController.helmCommand(_:)), keyEquivalent: key)
        item.keyEquivalentModifierMask = flags
        item.representedObject = command.rawValue
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }
    /// Finder's key for hidden files, beside Helm's Cmd+.
    private static func addViewAliases(to menu: NSMenu) {
        menu.addItem(hidden("Show Hidden Files", .hidden, ".", [.command, .shift]))
        for (title, key, selector) in [("Bigger Icons", "+", #selector(BrowserWindowController.biggerIcons(_:))),
                                       ("Bigger Icons", "=", #selector(BrowserWindowController.biggerIcons(_:))),
                                       ("Smaller Icons", "-", #selector(BrowserWindowController.smallerIcons(_:)))] {
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            item.keyEquivalentModifierMask = .command
            item.isHidden = true; item.allowsKeyEquivalentWhenHidden = true
            menu.addItem(item)
        }
    }
    private static func addTabAliases(to menu: NSMenu) {
        menu.addItem(hidden("Show Next Tab", .nextTab, "\t", .control))
        menu.addItem(hidden("Show Previous Tab", .previousTab, "\u{19}", [.control, .shift]))
    }
    private static func addQuickLookAlias(to menu: NSMenu) {
        menu.addItem(hidden("Quick Look", .quickLook, "y", .command))
    }

    private static func modifiers(_ value: KeyModifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if value.contains(.command) { flags.insert(.command) }
        if value.contains(.shift) { flags.insert(.shift) }
        if value.contains(.option) { flags.insert(.option) }
        if value.contains(.control) { flags.insert(.control) }
        return flags
    }
}
#endif
