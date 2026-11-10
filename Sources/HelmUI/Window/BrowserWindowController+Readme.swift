#if os(macOS)
import AppKit
import HelmCore

/// Hooks for the README's pictures, taken by `scripts/readme/make_readme_images.sh` over a made-up home folder.
extension BrowserWindowController {
    /// The free space the status bar names in place of the disk's own, so a picture never shows a real disk.
    /// Nil shows the real figure; a negative number leaves it out.
    public static var freeSpaceOverrideForTesting: Int64?

    /// Draws the status bar again, after the free space override changes.
    public func refreshStatusForTesting() {
        guard let tab = activeTab else { return }
        renderStatus(tab)
    }
}
#endif
