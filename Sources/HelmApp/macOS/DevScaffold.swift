// TEMPORARY SCAFFOLD: first Mac compile run only (docs/handoff/MAC_HANDOFF.md, Stage 3a).
// This is not the native host. It proves the process can launch and show one window using
// in-memory stores. The real host stays open under OK2-1, OK2-6, OK2-8, OK2-9 and OK2-10.
// Delete this file when the host lane lands.
#if os(macOS)
import AppKit
import SwiftUI
import HelmCore
import HelmFileSystem
import HelmUI

@MainActor public enum DevScaffold {
    /// Schedules the window for after `application.run()` starts. Exits 2 on a bad `--smoke-seconds`.
    public static func install(in application: NSApplication, arguments: [String]) {
        let smokeSeconds: Double?
        switch parseSmokeSeconds(arguments) {
        case .success(let value): smokeSeconds = value
        case .failure: fail("usage: HelmDev [--smoke-seconds N]", code: 2)
        }
        application.setActivationPolicy(.regular)
        Task { @MainActor in
            do {
                let environment = try await AppEnvironment.test()
                guard environment.fileSystem is InMemoryFileSystem else {
                    fail("HelmDev refuses to run without the in-memory filesystem", code: 1)
                }
                let window = showWindow(application: application)
                let visible = application.windows.filter(\.isVisible).count
                writeLine("HELMDEV_READY windows=\(visible) env=in-memory")
                // Keep the environment alive for as long as the window is open.
                keepAlive = (environment, window)
                if let smokeSeconds {
                    try await Task.sleep(nanoseconds: UInt64(smokeSeconds * 1_000_000_000))
                    application.terminate(nil)
                }
            } catch {
                fail("HelmDev could not start: \(error)", code: 1)
            }
        }
    }

    private static var keepAlive: (AppEnvironment, NSWindow)?
    private static var closeObserver: NSObjectProtocol?

    private enum UsageError: Error { case invalidSmokeSeconds }

    private static func parseSmokeSeconds(_ arguments: [String]) -> Result<Double?, UsageError> {
        let options = Array(arguments.dropFirst())
        if options.isEmpty { return .success(nil) }
        guard options.count == 2, options[0] == "--smoke-seconds", let seconds = Double(options[1]),
              seconds.isFinite, seconds >= 0, seconds <= 3_600 else { return .failure(.invalidSmokeSeconds) }
        return .success(seconds)
    }

    private static func showWindow(application: NSApplication) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 120),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "HelmDev (temporary scaffold)"
        window.isRestorable = false
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: StatusBarView(status: StatusPresentation(itemCount: 0)))
        // No menus exist here, so closing the only window has to end the process.
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                               object: window, queue: .main) { _ in
            MainActor.assumeIsolated { application.terminate(nil) }
        }
        window.center()
        // Shows the window without taking focus from whatever the user is doing.
        window.orderFrontRegardless()
        return window
    }

    private static func writeLine(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(code)
    }
}
#endif
