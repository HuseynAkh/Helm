#if os(macOS)
import AppKit
import HelmCore
import HelmUI

/// Smoke verbs for long names: the grid's two lines cut in the middle, the whole name while one item is selected,
/// the tooltip, what VoiceOver reads, the rename field, and the list's one line. Each reads the views on show.
extension HostSmokeDriver {
    static func performGridNamesVerb(_ verb: String, _ argument: String, step: String,
                                     window: BrowserWindowController, app: AppController) async -> Bool {
        switch verb {
        case "names-whole":
            // "<file name>": shown whole on two lines at most, or five while selected, with no tooltip.
            guard let report = window.gridNameForTesting(argument) else { check(false, step, "not in the grid"); return true }
            let limit = report.isExpanded ? 5 : 2
            check(!report.isShortened && report.lines.count <= limit && squeezed(report.lines.joined()) == squeezed(report.name)
                  && report.toolTip == nil && report.drawnLines == report.lines.count && spokenWhole(report, argument), step, describe(report))
        case "names-cut":
            // "<file name>": two lines, the second cut in the middle, keeping the start and the end of the name, its
            // extension too; the tooltip and VoiceOver have it whole.
            guard let report = window.gridNameForTesting(argument) else { check(false, step, "not in the grid"); return true }
            check(!report.isExpanded && report.lines.count == 2 && keepsStartAndEnd(report) && report.toolTip == report.name
                  && report.drawnLines == 2 && report.overflow == 0 && spokenWhole(report, argument), step, describe(report))
        case "names-open":
            // "<file name>", the one item selected: its whole name, up to five lines, drawn over the items below,
            // which cut away the part under it, with no tooltip since nothing's left out.
            guard let report = window.gridNameForTesting(argument) else { check(false, step, "not in the grid"); return true }
            check(report.isExpanded && !report.isShortened && report.lines.count <= 5 && squeezed(report.lines.joined()) == squeezed(report.name)
                  && report.toolTip == nil && report.drawnLines == report.lines.count && report.isOnTop
                  && (report.lines.count <= 2 || (report.overflow > 0 && report.coversBelow)) && spokenWhole(report, argument), step, describe(report))
        case "names-open-cut":
            // "<file name>", the one item selected, too long even for five lines: five, the fifth cut in the middle.
            guard let report = window.gridNameForTesting(argument) else { check(false, step, "not in the grid"); return true }
            check(report.isExpanded && report.lines.count == 5 && keepsStartAndEnd(report) && report.toolTip == report.name
                  && report.drawnLines == 5 && report.isOnTop && report.coversBelow && spokenWhole(report, argument), step, describe(report))
        case "names-all-drawn":
            // Every name in the grid is drawn on the lines worked out for it, two at most, none wrapped again.
            guard let tab = window.activeTab else { check(false, step, "no tab"); return true }
            let names = tab.snapshot.sortedEntries.prefix(tab.snapshot.rootCount).map(\.name)
            let wrong = names.filter { name in
                guard let report = window.gridNameForTesting(name) else { return true }
                return report.drawnLines != report.lines.count || report.lines.count > (report.isExpanded ? 5 : 2)
            }
            check(!names.isEmpty && wrong.isEmpty, step, wrong.isEmpty ? "no names" : "drawn wrong: \(wrong.joined(separator: " | "))")
        case "names-rename-whole":
            // Renames the one item selected: the field has the whole name and sits over the items below. Escape then
            // leaves the name as it was.
            guard let name = window.selectedEntries().first?.name else { check(false, step, "nothing selected"); return true }
            window.perform(.rename)
            await wait(seconds: 0.4)
            let editing = window.gridNameForTesting(name)
            let field = window.window?.firstResponder as? NSTextView
            check(editing?.fieldWords == editing?.name && editing?.name.isEmpty == false && editing?.isOnTop == true && field != nil,
                  step, editing.map(describe) ?? "not in the grid")
            field?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            await wait(seconds: 0.4)
            let after = window.gridNameForTesting(name)
            check(after?.fieldWords == nil && after?.isExpanded == true, "\(step) (Escape puts the lines back)", after.map(describe) ?? "gone")
        case "names-icons":
            // "<pixels>": the grid's icon size, as Cmd-+ and Cmd-- or the Settings slider set it.
            guard let pixels = Double(argument) else { check(false, step, "usage"); return true }
            window.dependencies.settings.set(.double(pixels), for: .gridIconSize)
            await wait(seconds: 0.4)
            let now = window.dependencies.settings.snapshot.double(.gridIconSize)
            check(now == pixels, step, "icons are \(now)")
        case "names-list-width":
            // "<points>": the list's Name column, as dragging its edge sets it.
            guard let points = Double(argument) else { check(false, step, "usage"); return true }
            check(window.setListNameWidthForTesting(CGFloat(points)), step, "no list")
            await wait(seconds: 0.3)
        case "names-list-whole", "names-list-cut":
            // "<file name>": the list shows all the words on one line, or, when the Name column is too narrow, cuts
            // them in the middle on one line. The words in the cell are always the whole name.
            guard let fit = window.listNameForTesting(argument) else { check(false, step, "not in the list"); return true }
            let whole = verb == "names-list-whole"
            check(fit.fitsWhole == whole && fit.lines == 1 && fit.cutsInMiddle && fit.words == argument, step,
                  "“\(fit.words)” \(fit.fitsWhole ? "fits" : "doesn't fit") a \(Int(fit.columnWidth))-point column on \(fit.lines) lines")
        default: return false
        }
        return true
    }

    private static func squeezed(_ text: String) -> String { text.filter { !$0.isWhitespace } }

    /// The first lines are the start of the name; the last has more of it, one ellipsis, then the end of the name,
    /// with the extension when it has one.
    private static func keepsStartAndEnd(_ report: GridNameReport) -> Bool {
        guard report.isShortened, let last = report.lines.last else { return false }
        let parts = last.components(separatedBy: "…")
        let name = squeezed(report.name)
        let start = squeezed(report.lines.dropLast().joined())
        guard parts.count == 2, name.hasPrefix(start), name.dropFirst(start.count).hasPrefix(squeezed(parts[0])),
              name.hasSuffix(squeezed(parts[1])) else { return false }
        let ending = URL(fileURLWithPath: report.name).pathExtension
        return ending.isEmpty || report.name.hasPrefix(".") || last.hasSuffix("." + ending)
    }

    /// VoiceOver reads the whole name, for the item and for the words under its icon.
    private static func spokenWhole(_ report: GridNameReport, _ fileName: String) -> Bool {
        report.spokenName == fileName && report.spokenWords == report.name
    }

    private static func describe(_ report: GridNameReport) -> String {
        let lines = report.lines.map { "«\($0)»" }.joined(separator: " ")
        return "\(lines), \(report.isShortened ? "shortened" : "whole"), \(report.isExpanded ? "open" : "closed"), drawn on \(report.drawnLines) lines, "
            + "tooltip \(report.toolTip.map { "«\($0)»" } ?? "none"), spoken «\(report.spokenName ?? "")» / «\(report.spokenWords ?? "")», "
            + "\(report.isOnTop ? "on top" : "not on top"), runs \(Int(report.overflow)) points past\(report.coversBelow ? ", hiding what's under it" : ""), "
            + "field \(report.fieldWords.map { "«\($0)»" } ?? "none")"
    }
}
#endif
