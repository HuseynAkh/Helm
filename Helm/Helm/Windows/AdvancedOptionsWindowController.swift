import Cocoa
import SwiftUI

class AdvancedOptionsWindowController: NSWindowController {
    static let shared = AdvancedOptionsWindowController()

    private init() {
        let optionsView = AdvancedOptionsView()
        let hostingController = NSHostingController(rootView: optionsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Advanced Options"
        window.styleMask = [.titled, .closable]
        window.setFrameAutosaveName("HelmAdvancedOptions")
        window.center()

        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showOptions() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
