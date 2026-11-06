#if os(macOS)
import AppKit

/// The entry point both the package executable and the Xcode app call.
@MainActor public enum HelmMain {
    private static var controller: AppController?

    public static func run() {
        guard let options = LaunchOptions.parse(CommandLine.arguments) else {
            FileHandle.standardError.write(Data("usage: Helm [--home PATH] [--support PATH] [--smoke SCRIPT] [PATH ...]\n".utf8))
            exit(2)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        let controller = AppController(options: options)
        self.controller = controller
        application.delegate = controller
        application.run()
    }
}
#endif
