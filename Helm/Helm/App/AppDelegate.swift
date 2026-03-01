import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {

    private var windowControllers: [MainWindowController] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppSettings.registerDefaults()
        createNewWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            createNewWindow()
        }
        return true
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        let url = URL(fileURLWithPath: filename)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: filename, isDirectory: &isDirectory) else {
            return false
        }

        if isDirectory.boolValue {
            if let windowController = windowControllers.first {
                windowController.navigateTo(url)
            } else {
                createNewWindow(at: url)
            }
            return true
        }

        // Opening a regular file should launch its default application.
        return NSWorkspace.shared.open(url)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        for filename in filenames {
            _ = application(sender, openFile: filename)
        }
    }

    @objc func newWindow(_ sender: Any?) {
        createNewWindow()
    }

    @objc func showPreferences(_ sender: Any?) {
        PreferencesWindowController.shared.showPreferences()
    }

    @objc func showAdvancedOptions(_ sender: Any?) {
        AdvancedOptionsWindowController.shared.showOptions()
    }

    @discardableResult
    private func createNewWindow(at url: URL? = nil) -> MainWindowController {
        let windowController: MainWindowController
        if let url {
            windowController = MainWindowController(initialURL: url)
        } else {
            windowController = MainWindowController()
        }
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        windowControllers.append(windowController)

        // Clean up when window closes
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: windowController.window, queue: .main) { [weak self] notification in
            self?.windowControllers.removeAll { $0.window == notification.object as? NSWindow }
        }

        return windowController
    }
}
