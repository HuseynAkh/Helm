#if os(macOS)
import AppKit
import SwiftUI

/// Helm's icon, which can be dragged into System Settings' Full Disk Access list. The drag carries the app
/// bundle's file URL, as dragging Helm from the Applications folder would.
struct AppIconDragSource: NSViewRepresentable {
    let appURL: URL?
    let image: NSImage

    func makeNSView(context: Context) -> AppIconDragView { AppIconDragView(appURL: appURL, image: image) }
    func updateNSView(_ view: AppIconDragView, context: Context) {
        view.appURL = appURL
        if view.image !== image { view.image = image; view.needsDisplay = true }
    }
    /// As big as the frame it's given, rather than its own 64 points spilling over a smaller one.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AppIconDragView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 64, height: proposal.height ?? 64)
    }
}

@MainActor final class AppIconDragView: NSView, NSDraggingSource {
    var appURL: URL?
    var image: NSImage

    init(appURL: URL?, image: NSImage) {
        self.appURL = appURL; self.image = image
        super.init(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        // The + route is here for anyone who can't drag: the steps beside the icon leave it out.
        setAccessibilityLabel("Helm icon: drag it into the Full Disk Access list, or click + there and choose Helm.")
    }
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 64, height: 64) }
    /// A click in System Settings' direction mustn't bring Helm forward first, or the list would be covered.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func resetCursorRects() {
        if appURL != nil { addCursorRect(bounds, cursor: .openHand) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let side = min(bounds.width, bounds.height)
        let rect = NSRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: appURL == nil ? 0.45 : 1)
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {
        guard let appURL else { return }
        let item = NSDraggingItem(pasteboardWriter: appURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }
}
#endif
