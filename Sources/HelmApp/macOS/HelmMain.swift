#if os(macOS)
import AppKit
import HelmUI

/// The entry point both the package executable and the Xcode app call.
@MainActor public enum HelmMain {
    private static var controller: AppController?

    public static func run() {
        guard let options = LaunchOptions.parse(CommandLine.arguments) else {
            FileHandle.standardError.write(Data(LaunchOptions.usage.utf8))
            exit(2)
        }
        if options.isRoleCommand { exit(RoleCommand.run(options)) }
        let application = HelmApplication.shared
        application.setActivationPolicy(.regular)
        let controller = AppController(options: options)
        self.controller = controller
        application.delegate = controller
        application.run()
    }
}

/// Helm's application. AppKit's own handler for an open-documents event asks to bring Helm to the front, and Helm's
/// code asks too. A scripted run never comes to the front, so while one goes on, those asks are turned down.
@MainActor final class HelmApplication: NSApplication {
    private var staysInBackground: Bool { (delegate as? AppController)?.staysInBackground == true }

    override func activate() {
        if !staysInBackground { super.activate() }
    }
    override func activate(ignoringOtherApps flag: Bool) {
        if !staysInBackground { super.activate(ignoringOtherApps: flag) }
    }
    /// Comes to the front even in a scripted run, for a step that means to, such as the README's pictures.
    func activateForScript() { super.activate(ignoringOtherApps: true) }
}

/// The Settings › General › Default File Viewer switches, run from the command line with no window, so either
/// change can be made or undone from Terminal: `/Applications/Helm.app/Contents/MacOS/Helm --default-viewer finder`.
@MainActor enum RoleCommand {
    static func run(_ options: LaunchOptions) -> Int32 {
        let role = SystemFileViewerRole()
        guard role.canRegister else { print("Run this from Helm.app, not the bare executable."); return 2 }
        var failed = false
        if let helm = options.defaultViewer {
            var finished = false
            let done: @MainActor (String?) -> Void = { message in
                if let message { print("Default viewer: \(message)"); failed = true }
                finished = true
            }
            if helm { role.makeHelmDefault(done) } else { role.restoreFinder(done) }
            // The folder handler answers on the run loop.
            let deadline = Date().addingTimeInterval(15)
            while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            if !finished { print("Default viewer: macOS didn’t answer."); failed = true }
        }
        if let first = options.dockFirst {
            if let message = role.setFirstInDock(first) { print("Dock: \(message)"); failed = true }
            // Give the Dock time to come back, and Helm time to write again if it saved its old tiles.
            let deadline = Date().addingTimeInterval(9)
            while Date() < deadline && role.isFirstInDock != first { RunLoop.main.run(until: Date().addingTimeInterval(0.25)) }
            RunLoop.main.run(until: Date().addingTimeInterval(1))
        }
        print("File viewer: \(role.isHelmDefault ? "Helm" : "Finder")")
        print("Folders opened from Spotlight and the Dock: \(role.opensFolders ? "Helm" : "Finder (macOS keeps this)")")
        print("Helm first in the Dock: \(role.isFirstInDock ? "yes" : "no")")
        return failed ? 1 : 0
    }
}
#endif
