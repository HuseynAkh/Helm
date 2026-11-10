import AppKit
import HelmApp

// Top-level code runs on the main thread, but this compiler treats it as nonisolated.
MainActor.assumeIsolated {
    HelmMain.run()
}
