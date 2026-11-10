#if os(macOS)
import AppKit
import HelmCore
import HelmUI

/// Smoke verbs for the grid's thumbnails: every picture in the folder on show gets its own, within a few seconds.
/// They read the items on show, so what's checked is what a person would see.
extension HostSmokeDriver {
    static func performThumbnailsVerb(_ verb: String, _ argument: String, step: String,
                                      window: BrowserWindowController, app: AppController) async -> Bool {
        switch verb {
        case "thumbnails-shown":
            // "<seconds>": before that long is up, every picture in the grid shows its own thumbnail, not an icon.
            guard let limit = Double(argument) else { check(false, step, "usage: thumbnails-shown <seconds>"); return true }
            let start = Date()
            var reports = window.gridThumbnailsForTesting()
            while let shown = reports, !shown.isEmpty, !shown.allSatisfy(\.hasThumbnail), Date().timeIntervalSince(start) < limit {
                await wait(seconds: 0.1)
                reports = window.gridThumbnailsForTesting()
            }
            guard let reports else { check(false, step, "the grid isn't on show"); return true }
            let missing = reports.filter { !$0.hasThumbnail }.map { "\($0.name): \($0.shows)" }
            check(!reports.isEmpty && missing.isEmpty, step,
                  reports.isEmpty ? "no pictures in the grid" : "after \(argument) seconds, " + missing.joined(separator: ", "))
        default: return false
        }
        return true
    }
}
#endif
