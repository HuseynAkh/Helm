#if os(macOS)
import AppKit
import HelmCore

/// The location bar while it's being typed in: a press anywhere else in the window closes it, as Escape does, and
/// goes nowhere. That covers places that never take the keys, such as the AI panel's thread and chips or the header
/// around the bar, as well as the files, the sidebar and the tabs. The completion list is a window of its own, so a
/// press there is the list's.
extension BrowserWindowController {
    /// Watches for presses only while the location is being typed in.
    func followLocationEditing(_ editing: Bool) {
        if editing, locationPressWatch == nil {
            locationPressWatch = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, event.window === self.window else { return }
                    self.pointerWentDown(at: event.locationInWindow)
                }
                return event
            }
        } else if !editing, let watch = locationPressWatch {
            NSEvent.removeMonitor(watch)
            locationPressWatch = nil
        }
    }

    /// A press at `point`, in the window's coordinates. Outside the location bar it closes the bar without going
    /// anywhere, before the press reaches what is under it, so a press on the composer still gives it the keys.
    func pointerWentDown(at point: NSPoint) {
        guard closesLocation(at: point) else { return }
        pathBarAction(.cancel)
    }

    /// Whether a press at `point` closes the location bar: it's being typed in, it's on show, and the press is outside it.
    func closesLocation(at point: NSPoint) -> Bool {
        guard activeTab?.addressBar.isEditing == true, !pathBar.isHiddenOrHasHiddenAncestor else { return false }
        return !pathBar.bounds.contains(pathBar.convert(point, from: nil))
    }

    // MARK: Test support

    /// Whether presses elsewhere are being watched for, which is only while the location is being typed in.
    public var watchesLocationPressesForTesting: Bool { locationPressWatch != nil }
    /// A press in the middle of a part of the window, as a person's click there: path, panel, files, sidebar or header.
    /// False when that part isn't on show.
    @discardableResult public func pressForTesting(in part: String) -> Bool {
        let view: NSView?
        switch part {
        case "path": view = pathBar
        case "panel": view = agentPanelHost.isOpen ? agentPanelHost : nil
        case "files": view = contentContainer
        case "sidebar": view = sidebar.view
        case "header": view = header
        default: view = nil
        }
        guard let view, !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 0, view.bounds.height > 0 else { return false }
        // The header's middle is the path bar, so a press on the header lands at its trailing edge instead.
        let local = part == "header" ? NSPoint(x: view.bounds.maxX - 4, y: view.bounds.midY) : NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        pointerWentDown(at: view.convert(local, to: nil))
        return true
    }
}
#endif
