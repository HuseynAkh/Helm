import Cocoa

// Set up the application as a regular GUI app (not background/accessory)
let app = NSApplication.shared
app.setActivationPolicy(.regular)

// Create and assign the delegate
let delegate = AppDelegate()
app.delegate = delegate

// Build the main menu bar
let mainMenu = NSMenu()

// App menu
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenuItem.submenu = appMenu
appMenu.addItem(NSMenuItem(title: "About Helm", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
appMenu.addItem(NSMenuItem.separator())

let preferencesItem = NSMenuItem(title: "Settings...", action: #selector(AppDelegate.showPreferences(_:)), keyEquivalent: ",")
preferencesItem.target = delegate
appMenu.addItem(preferencesItem)
let advancedOptionsItem = NSMenuItem(title: "Advanced Options...", action: #selector(AppDelegate.showAdvancedOptions(_:)), keyEquivalent: "")
advancedOptionsItem.target = delegate
appMenu.addItem(advancedOptionsItem)
appMenu.addItem(NSMenuItem.separator())

let servicesMenuItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
let servicesMenu = NSMenu(title: "Services")
servicesMenuItem.submenu = servicesMenu
app.servicesMenu = servicesMenu
appMenu.addItem(servicesMenuItem)
appMenu.addItem(NSMenuItem.separator())

appMenu.addItem(NSMenuItem(title: "Hide Helm", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
hideOthersItem.keyEquivalentModifierMask = [.command, .option]
appMenu.addItem(hideOthersItem)
appMenu.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
appMenu.addItem(NSMenuItem.separator())
appMenu.addItem(NSMenuItem(title: "Quit Helm", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

// File menu
let fileMenuItem = NSMenuItem()
mainMenu.addItem(fileMenuItem)
let fileMenu = NSMenu(title: "File")
fileMenuItem.submenu = fileMenu
fileMenu.addItem(NSMenuItem(title: "New Window", action: #selector(AppDelegate.newWindow(_:)), keyEquivalent: "n"))
fileMenu.addItem(NSMenuItem(title: "New Tab", action: #selector(MainWindowController.newTab), keyEquivalent: "t"))
fileMenu.addItem(NSMenuItem.separator())
let newFolderItem = NSMenuItem(title: "New Folder", action: #selector(MainWindowController.performNewFolder), keyEquivalent: "N")
newFolderItem.keyEquivalentModifierMask = [.command, .shift]
fileMenu.addItem(newFolderItem)
fileMenu.addItem(NSMenuItem.separator())
fileMenu.addItem(NSMenuItem.separator())
fileMenu.addItem(NSMenuItem(title: "Find...", action: #selector(MainWindowController.toggleSearch), keyEquivalent: "f"))
fileMenu.addItem(NSMenuItem.separator())
fileMenu.addItem(NSMenuItem(title: "Close Tab", action: #selector(MainWindowController.closeTab), keyEquivalent: "w"))

// Edit menu
let editMenuItem = NSMenuItem()
mainMenu.addItem(editMenuItem)
let editMenu = NSMenu(title: "Edit")
editMenuItem.submenu = editMenu
editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
redoItem.keyEquivalentModifierMask = [.command, .shift]
editMenu.addItem(redoItem)
editMenu.addItem(NSMenuItem.separator())
editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(MainWindowController.performCut), keyEquivalent: "x"))
editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(MainWindowController.performCopy), keyEquivalent: "c"))
editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(MainWindowController.performPaste), keyEquivalent: "v"))
editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
editMenu.addItem(NSMenuItem.separator())
let renameItem = NSMenuItem(title: "Rename", action: #selector(MainWindowController.performRename), keyEquivalent: "\r")
renameItem.keyEquivalentModifierMask = []
editMenu.addItem(renameItem)
let trashItem = NSMenuItem(title: "Move to Trash", action: #selector(MainWindowController.performTrash), keyEquivalent: "\u{8}")
trashItem.keyEquivalentModifierMask = [.command]
editMenu.addItem(trashItem)
editMenu.addItem(NSMenuItem.separator())
editMenu.addItem(NSMenuItem(title: "Properties", action: #selector(MainWindowController.performProperties), keyEquivalent: "i"))

// View menu
let viewMenuItem = NSMenuItem()
mainMenu.addItem(viewMenuItem)
let viewMenu = NSMenu(title: "View")
viewMenuItem.submenu = viewMenu

viewMenu.addItem(NSMenuItem(title: "as Grid", action: #selector(MainWindowController.switchToGridView), keyEquivalent: "1"))
viewMenu.addItem(NSMenuItem(title: "as List", action: #selector(MainWindowController.switchToListView), keyEquivalent: "2"))
viewMenu.addItem(NSMenuItem.separator())

let toggleSidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(MainWindowController.toggleSidebar), keyEquivalent: "s")
toggleSidebarItem.keyEquivalentModifierMask = [.command, .control]
viewMenu.addItem(toggleSidebarItem)
viewMenu.addItem(NSMenuItem.separator())

viewMenu.addItem(NSMenuItem(title: "Show Hidden Files", action: #selector(MainWindowController.toggleHiddenFiles), keyEquivalent: "."))
viewMenu.addItem(NSMenuItem.separator())

let refreshItem = NSMenuItem(title: "Refresh", action: #selector(MainWindowController.refreshDirectory), keyEquivalent: "r")
viewMenu.addItem(refreshItem)

// Go menu
let goMenuItem = NSMenuItem()
mainMenu.addItem(goMenuItem)
let goMenu = NSMenu(title: "Go")
goMenuItem.submenu = goMenu
goMenu.addItem(NSMenuItem(title: "Back", action: #selector(MainWindowController.goBack), keyEquivalent: "["))
goMenu.addItem(NSMenuItem(title: "Forward", action: #selector(MainWindowController.goForward), keyEquivalent: "]"))
let enclosingItem = NSMenuItem(title: "Enclosing Folder", action: #selector(MainWindowController.goUp), keyEquivalent: String(Character(UnicodeScalar(NSUpArrowFunctionKey)!)))
enclosingItem.keyEquivalentModifierMask = [.command]
goMenu.addItem(enclosingItem)
goMenu.addItem(NSMenuItem.separator())
goMenu.addItem(NSMenuItem(title: "Home", action: #selector(MainWindowController.goHome), keyEquivalent: "H"))
goMenu.addItem(NSMenuItem.separator())
let editPathItem = NSMenuItem(title: "Go to Folder...", action: #selector(MainWindowController.editPathBar), keyEquivalent: "l")
goMenu.addItem(editPathItem)
goMenu.addItem(NSMenuItem.separator())
let starItem = NSMenuItem(title: "Toggle Star", action: #selector(MainWindowController.performToggleStar), keyEquivalent: "d")
goMenu.addItem(starItem)

// Window menu
let windowMenuItem = NSMenuItem()
mainMenu.addItem(windowMenuItem)
let windowMenu = NSMenu(title: "Window")
windowMenuItem.submenu = windowMenu
windowMenu.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
windowMenu.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
windowMenu.addItem(NSMenuItem.separator())
windowMenu.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
app.windowsMenu = windowMenu

// Help menu
let helpMenuItem = NSMenuItem()
mainMenu.addItem(helpMenuItem)
let helpMenu = NSMenu(title: "Help")
helpMenuItem.submenu = helpMenu
app.helpMenu = helpMenu

app.mainMenu = mainMenu

// Activate and run
app.activate(ignoringOtherApps: true)
app.run()
