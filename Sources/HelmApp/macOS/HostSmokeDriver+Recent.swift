#if os(macOS)
import AppKit
import HelmCore
import HelmPersistence
import HelmUI

/// Smoke verbs for Recent: folders apart from files.
extension HostSmokeDriver {
    static func performRecentVerb(_ verb: String, _ argument: String, step: String,
                              window: BrowserWindowController, app: AppController) async -> Bool {
        switch verb {
        case "recent-record":
            // As opening a file records it: files only get into Recent by being opened, which a scripted run can't do.
            var directory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: argument, isDirectory: &directory)
            check(exists, step, "no such item")
            window.dependencies.recents.recordAccess(to: URL(fileURLWithPath: argument), kind: directory.boolValue ? .directory : .regular, at: Date())
            await wait(seconds: 0.05)
        case "sections":
            // "Folders 2,Files 2", or "none" for one plain run with no headings.
            let sections = window.contentSectionsForTesting().joined(separator: ",")
            check(sections == (argument == "none" ? "" : argument), step, sections.isEmpty ? "none" : sections)
        case "folders-first":
            guard let sort = window.activeTab?.sort else { check(false, step, "no tab"); return true }
            window.contentSetSortForTesting(ItemSort(field: sort.field, ascending: sort.ascending, directoriesFirst: argument == "on"))
            await wait(seconds: 0.4)
        case "content-key":
            check(window.contentKeyForTesting(argument), step, "no such key")
            await wait(seconds: 0.3)
        case "sort-last-opened":
            // Presses Last Opened, as its row in View Options does.
            window.pressSort(.lastOpened)
            await wait(seconds: 0.4)
        default: return false
        }
        return true
    }
}
#endif
