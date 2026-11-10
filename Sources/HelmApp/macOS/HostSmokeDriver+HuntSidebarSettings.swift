#if os(macOS)
import AppKit
import HelmCore
import HelmUI

/// Smoke verbs for the sidebar, Settings and the welcome window. They reach the real views through AppKit itself (the
/// view tree, the menus and key events), so no product code needs a hook of its own.
/// Steps: scripts/rebuild/smoke.d/hunt-sidebar-settings.txt.
extension HostSmokeDriver {
    static func performHuntSidebarSettingsVerb(_ verb: String, _ argument: String, step: String,
                                               window: BrowserWindowController, app: AppController) async -> Bool {
        switch verb {
        case "hunt-settings-open":
            // hunt-settings-open <pane>: Settings opens at that pane and stays open, as a person would leave it.
            guard let pane = SettingsPane.allCases.first(where: { $0.rawValue.lowercased() == argument }) else {
                check(false, step, "no such pane"); return true
            }
            app.showSettingsWindow(nil)
            app.settingsControllerForTesting?.select(pane)
            await wait(seconds: 0.8)
            check(app.settingsWindowForTesting?.isVisible == true, step, "Settings isn't open")
        case "hunt-settings-close":
            app.settingsWindowForTesting?.close()
            await wait(seconds: 0.3)
        case "hunt-settings-pane-is":
            // hunt-settings-pane-is <pane>: Settings is open, at this pane. Leaves it open.
            let pane = app.settingsControllerForTesting?.selectedPane?.rawValue.lowercased() ?? "none"
            let open = app.settingsWindowForTesting?.isVisible == true
            check(open && pane == argument, step, "open \(open), pane \(pane)")
        case "hunt-settings-reads":
            // hunt-settings-reads <text>: what one of the open pane's controls shows, as "Kind: value", contains this.
            let texts = controlTexts(app.settingsWindowForTesting?.contentView)
            check(texts.contains { $0.contains(argument) }, step, texts.joined(separator: " | "))
        case "hunt-settings-switches":
            // hunt-settings-switches <on|off,…>: the open pane's switches, top to bottom, as they're drawn.
            let states = controlTexts(app.settingsWindowForTesting?.contentView).filter { $0.hasPrefix("Switch: ") }
                .map { String($0.dropFirst("Switch: ".count)) }
            check(states.joined(separator: ",") == argument, step, states.joined(separator: ","))
        case "hunt-settings-squeeze":
            // hunt-settings-squeeze <content height>: the Settings window as tall as a short screen leaves it.
            guard let settings = app.settingsWindowForTesting, let height = Double(argument) else { check(false, step, "no window"); return true }
            var frame = settings.frame
            let size = settings.frameRect(forContentRect: NSRect(x: 0, y: 0, width: settings.contentLayoutRect.width, height: height)).size
            frame.origin.y += frame.height - size.height
            frame.size = size
            settings.setFrame(frame, display: true, animate: false)
            await wait(seconds: 0.5)
        case "hunt-settings-reachable":
            // Everything in the open pane can be seen, or scrolled to: no scroll area runs past the window's edges while
            // also showing all it holds, which would leave the part past the edge out of reach.
            guard let content = app.settingsWindowForTesting?.contentView else { check(false, step, "no window"); return true }
            let bounds = content.bounds
            var problems: [String] = []
            func walk(_ view: NSView) {
                if let scroll = view as? NSScrollView, let document = scroll.documentView {
                    let frame = scroll.convert(scroll.bounds, to: content)
                    let insets = scroll.contentInsets
                    let showsAll = document.frame.height <= scroll.contentView.bounds.height - insets.top - insets.bottom + 1
                    let overhang = max(0, frame.maxY - bounds.maxY) + max(0, bounds.minY - frame.minY)
                    if overhang > 1 && showsAll {
                        problems.append("a scroll area \(Int(frame.height)) tall runs \(Int(overhang)) points past a window \(Int(bounds.height)) tall, and can't scroll")
                    }
                    return
                }
                view.subviews.forEach(walk)
            }
            walk(content)
            check(problems.isEmpty, step, problems.joined(separator: "; "))
        case "hunt-app-menu":
            // hunt-app-menu <title>: chooses an item in the Helm menu, as a click on it does.
            guard let menu = NSApp.mainMenu?.items.first?.submenu,
                  let index = menu.items.firstIndex(where: { $0.title == argument }) else { check(false, step, "no such item"); return true }
            menu.update()
            guard menu.items[index].isEnabled else { check(false, step, "disabled"); return true }
            menu.performActionForItem(at: index)
            await wait(seconds: 0.8)
        case "hunt-key-closes":
            // hunt-key-closes settings|welcome: ⌘W, pressed with that window in front, closes it. The window comes to the
            // front first, as a click on it brings it, and the key goes to the menu bar, as AppKit sends a key equivalent.
            // A scripted run isn't the active app, so no window is key; the menu acts on the window in front.
            let target = argument == "welcome" ? app.onboardingForTesting?.window : app.settingsWindowForTesting
            guard let target, target.isVisible else { check(false, step, "not open"); return true }
            target.orderFrontRegardless()
            target.makeKey()
            await wait(seconds: 0.3)
            guard let menu = NSApp.mainMenu,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber,
                                               context: nil, characters: "w", charactersIgnoringModifiers: "w",
                                               isARepeat: false, keyCode: 13) else { check(false, step, "no key event"); return true }
            let handled = menu.performKeyEquivalent(with: event)
            await wait(seconds: 0.5)
            check(!target.isVisible, step, "handled \(handled), key window “\(NSApp.keyWindow?.title ?? "none")”, still open")
        case "hunt-sidebar-focus":
            // The sidebar's list takes the keys, as after a click on one of its rows, or Tab.
            guard let outline = placesList(in: window) else { check(false, step, "no sidebar list"); return true }
            check(window.window?.makeFirstResponder(outline) == true, step, "the list wouldn't take the keys")
            await wait(seconds: 0.2)
        case "hunt-sidebar-key":
            // hunt-sidebar-key down|up|return: a key pressed while the sidebar's list has the keys.
            guard let outline = placesList(in: window), let event = keyEvent(argument, window: window.window) else {
                check(false, step, "no sidebar list, or no such key"); return true
            }
            window.window?.makeFirstResponder(outline)
            outline.keyDown(with: event)
            await wait(seconds: 0.6)
        case "hunt-focus-is":
            check(window.focusOwnerForTesting == argument, step, window.focusOwnerForTesting)
        default:
            return false
        }
        return true
    }

    /// The sidebar's list, found by its accessibility label in the window's own view tree.
    private static func placesList(in window: BrowserWindowController) -> NSOutlineView? {
        func find(_ view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView, outline.accessibilityLabel() == "Places" { return outline }
            for child in view.subviews { if let found = find(child) { return found } }
            return nil
        }
        return window.window?.contentView.flatMap(find)
    }

    private static func keyEvent(_ name: String, window: NSWindow?) -> NSEvent? {
        let keys: [String: (String, UInt16)] = ["down": ("\u{F701}", 125), "up": ("\u{F700}", 126), "return": ("\r", 36)]
        guard let (characters, code) = keys[name] else { return nil }
        let flags: NSEvent.ModifierFlags = code >= 123 ? [.numericPad, .function] : []
        return NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: window?.windowNumber ?? 0, context: nil, characters: characters,
                                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
    }

    /// What the AppKit controls under a view show: SwiftUI draws Form controls with them, and their text and values are
    /// what's on screen. Each reads "Kind: what it shows".
    private static func controlTexts(_ root: NSView?) -> [String] {
        guard let root else { return [] }
        var texts: [String] = []
        func walk(_ view: NSView) {
            if view.isHiddenOrHasHiddenAncestor { return }
            switch view {
            case let slider as NSSlider: texts.append("Slider: \(slider.doubleValue)")
            case let stepper as NSStepper: texts.append("Stepper: \(stepper.integerValue)")
            case let popUp as NSPopUpButton: texts.append("PopUp: \(popUp.titleOfSelectedItem ?? "")")
            case let segments as NSSegmentedControl:
                texts.append("Segments: \(segments.selectedSegment >= 0 ? segments.label(forSegment: segments.selectedSegment) ?? "" : "none")")
            case let toggle as NSSwitch: texts.append("Switch: \(toggle.state == .on ? "on" : "off")")
            case let button as NSButton: texts.append("Button: \(button.title)\(button.state == .on ? " on" : "") enabled=\(button.isEnabled)")
            case let field as NSTextField: texts.append("Text: \(field.stringValue)")
            default: break
            }
            for child in view.subviews { walk(child) }
        }
        walk(root)
        return texts
    }
}
#endif
