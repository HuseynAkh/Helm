#if os(macOS)
import AppKit

/// The AI panel's column: under the header, beside the files, as wide as `width` while open and zero wide while shut.
/// The tab strip, the files, the operations rows and the status bar end at its leading edge. It holds nothing, so it
/// stays shut.
@MainActor final class AgentPanelHost: NSView {
    static let width: CGFloat = 340, minimumFilesWidth: CGFloat = 420

    /// Zero while shut, `width` while open. The window activates it with the rest of its layout.
    private(set) lazy var widthConstraint: NSLayoutConstraint = widthAnchor.constraint(equalToConstant: 0)
    private weak var browser: BrowserWindowController?

    var isOpen: Bool { false }
    /// Whether the keys are in the panel: its first responder is the panel or inside it.
    var holdsKeys: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: self)
    }
    /// Called once, after the window has laid out its content.
    func install(in window: BrowserWindowController) { browser = window }
    func setOpen(_ open: Bool, animated: Bool) {}
    /// The tab, its folder or its selection may have changed.
    func windowDidRender() {}
}
#endif
