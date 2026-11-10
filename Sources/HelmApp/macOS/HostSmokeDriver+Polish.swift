#if os(macOS)
import AppKit
import QuartzCore
import HelmCore
import HelmUI

/// Smoke verbs for polish: list animation.
extension HostSmokeDriver {
    static func performPolishVerb(_ verb: String, _ argument: String, step: String,
                              window: BrowserWindowController, app: AppController) async -> Bool {
        await performListMotionVerb(verb, argument, step: step, window: window)
    }

    /// The list's reload count when `list-mark` last ran.
    private static var listReloadMark = 0

    /// Opening and closing folders in the list, through the real disclosure triangle.
    private static func performListMotionVerb(_ verb: String, _ argument: String, step: String,
                                              window: BrowserWindowController) async -> Bool {
        let tab = window.activeTab
        switch verb {
        case "disclose":
            // Clicks the triangle of the row with this name, then waits for the rows to move.
            check(window.discloseInListForTesting(argument), step, "no such row, or no triangle")
            await wait(seconds: 0.6)
        case "disclose-now":
            // Clicks the triangle and checks straight away, before any fresh listing can arrive.
            check(window.discloseInListForTesting(argument), step, "no such row, or no triangle")
        case "list-lacks":
            let shown = window.listRowNamesForTesting
            check(!shown.isEmpty && !shown.contains(argument), step, shown.joined(separator: ","))
        case "list-loading":
            // The folder with this name shows its Loading row while its listing is on the way.
            check(window.listShowsLoadingRowForTesting(argument), step, window.listRowNamesForTesting.joined(separator: ","))
        case "child-delay":
            // Seconds every folder listing opened in the list is held back, standing in for a slow disk.
            BrowserWindowController.childListingDelayForTesting = Double(argument) ?? 0
        case "motion-sample":
            // "<folder>/<first row inside it>": opens the folder by its triangle and watches that row arrive, then
            // closes it and watches the row leave, reading what Core Animation draws. Part way through the row must
            // be moving (faded or not yet in place), and afterwards settled, then gone.
            let parts = argument.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { check(false, step, "usage: folder/row"); return true }
            var start = CACurrentMediaTime()
            guard window.discloseInListForTesting(parts[0]) else { check(false, step, "no such folder"); return true }
            var arriving: [RowMotion] = []
            for pause in [0.02, 0.05, 0.05, 0.05, 0.05] {
                await wait(seconds: pause)
                arriving.append(RowMotion(window.listRowViewForTesting(parts[1]), since: start))
            }
            await wait(seconds: 0.5)
            let settled = RowMotion(window.listRowViewForTesting(parts[1]), since: start)
            let leavingView = window.listRowViewForTesting(parts[1])
            start = CACurrentMediaTime()
            guard window.discloseInListForTesting(parts[0]) else { check(false, step, "the folder went"); return true }
            var leaving: [RowMotion] = []
            for pause in [0.02, 0.05, 0.05, 0.05, 0.05] {
                await wait(seconds: pause)
                leaving.append(RowMotion(leavingView, since: start))
            }
            await wait(seconds: 0.5)
            let gone = RowMotion(leavingView, since: start)
            let report = "arriving \(arriving.map(\.text)) settled \(settled.text) leaving \(leaving.map(\.text)) gone \(gone.text)"
            print("MOTION \(report)")
            check(arriving.contains(where: \.isMoving) && settled.isSettled, step + " (arriving)", report)
            check(leaving.contains(where: \.isMoving) && gone.isGone, step + " (leaving)", report)
        case "list-in-step":
            // What the list shows, row by row, is what the store says is visible.
            let shown = window.listRowNamesForTesting
            let visible = tab.map { value in value.snapshot.visibleIDs(expanding: value.expandedIDs).compactMap { value.snapshot.entry($0)?.name } } ?? []
            check(!shown.isEmpty && shown == visible, step, "list \(shown.joined(separator: ",")) store \(visible.joined(separator: ","))")
        case "list-rows":
            let shown = window.listRowNamesForTesting.joined(separator: ",")
            check(shown == argument, step, shown)
        case "list-open":
            let open = window.listIsOpenForTesting(argument)
            check(open == true, step, open.map { "open \($0)" } ?? "no such row")
        case "list-closed":
            let open = window.listIsOpenForTesting(argument)
            check(open == false, step, open.map { "open \($0)" } ?? "no such row")
        case "list-selected":
            // The rows the list itself shows selected, which must match the store's selection.
            let shown = window.listSelectedNamesForTesting.joined(separator: ",")
            check(shown == argument, step, shown)
        case "list-mark":
            listReloadMark = window.listReloadsForTesting
        case "list-reloads":
            let count = window.listReloadsForTesting - listReloadMark
            check(count == Int(argument), step, "\(count) full reloads")
        default: return false
        }
        return true
    }
}

/// How a list row looks on screen right now, read from what Core Animation draws rather than where the row will end
/// up. AppKit moves rows by animating their row views' positions, and fades and unrolls rows coming or going inside a
/// container it puts around them, so this reads every layer from the row up to the list.
@MainActor private struct RowMotion {
    let elapsed: CFTimeInterval
    let attached: Bool
    /// The row's own opacity times its containers'.
    let opacity: Float
    /// Whether the row or a container around it has an animation running.
    let animating: Bool
    init(_ view: NSView?, since start: CFTimeInterval) {
        elapsed = CACurrentMediaTime() - start
        var opacity: Float = view == nil ? 0 : 1
        var animating = false
        var current = view
        var inList = false
        while let layered = current, !(layered is NSTableView) {
            if let layer = layered.layer {
                opacity *= (layer.presentation() ?? layer).opacity
                if !(layer.animationKeys() ?? []).isEmpty { animating = true }
            }
            if layered.isHidden { opacity = 0 }
            current = layered.superview
            inList = current is NSTableView
        }
        self.opacity = opacity
        self.animating = animating
        attached = inList || animating
    }
    /// Part way in or out: an animation is running on it, or it's faded.
    var isMoving: Bool { attached && (animating || opacity < 0.97) }
    var isSettled: Bool { attached && !animating && opacity > 0.99 }
    var isGone: Bool { !attached || opacity < 0.01 }
    var text: String {
        String(format: "%.0fms %.2f%@", elapsed * 1000, opacity, attached ? (animating ? " moving" : "") : " off")
    }
}
#endif
