// TEMPORARY entry point for the first Mac compile run; see DevScaffold.swift in HelmApp.
import AppKit
import HelmApp

// Top-level code runs on the main thread, but this compiler treats it as nonisolated.
MainActor.assumeIsolated {
    let application = NSApplication.shared
    DevScaffold.install(in: application, arguments: CommandLine.arguments)
    application.run()
}
