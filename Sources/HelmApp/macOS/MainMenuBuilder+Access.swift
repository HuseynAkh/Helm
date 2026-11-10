#if os(macOS)
import AppKit

extension MainMenuBuilder {
    /// Help › Set Up Helm… and Help › Full Disk Access…, so the welcome checklist and its guide are always within reach.
    static func addAccessItems(to menu: NSMenu, target: AppController) {
        menu.addItem(.separator())
        for (title, action) in [("Set Up Helm…", #selector(AppController.showSetup(_:))),
                                ("Full Disk Access…", #selector(AppController.showFullDiskAccessGuide(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
    }
}
#endif
