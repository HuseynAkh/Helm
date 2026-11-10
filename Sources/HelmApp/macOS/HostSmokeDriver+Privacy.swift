#if os(macOS)
import AppKit
import HelmCore
import HelmPersistence
import HelmUI

/// Smoke verbs for privacy: what Helm keeps about you, and when it reads the clipboard.
/// They use only the fixture run's own pasteboard and support folder.
extension HostSmokeDriver {
    /// Gives its contents only when something reads them, and counts the reads.
    private final class LazyClipboard: NSObject, NSPasteboardItemDataProvider {
        let contents: String
        private(set) var reads = 0
        init(_ contents: String) { self.contents = contents }
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            reads += 1
            item.setString(contents, forType: type)
        }
    }
    private static var lazyClipboard: LazyClipboard?

    static func performPrivacyVerb(_ verb: String, _ argument: String, step: String,
                                   window: BrowserWindowController, app: AppController) async -> Bool {
        let pasteboard = window.dependencies.pasteboard
        switch verb {
        case "clipboard-text":
            // The clipboard's text, one line per item, written here with commas between them.
            let text = pasteboard.string(forType: .string) ?? ""
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false).joined(separator: ",")
            check(lines == argument, step, lines)
        case "clipboard-files":
            let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
            check(urls.count == Int(argument), step, "\(urls.count) files")
        case "clipboard-lazy":
            // clipboard-lazy text <words> | files <path>: puts something on the clipboard that's read only on request.
            let bits = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard pasteboard.name != .general, bits.count == 2 else { check(false, step, "refused: not a fixture pasteboard, or no contents"); return true }
            let files = bits[0] == "files"
            let provider = LazyClipboard(files ? URL(fileURLWithPath: bits[1]).absoluteString : bits[1])
            lazyClipboard = provider
            let item = NSPasteboardItem()
            item.setDataProvider(provider, forTypes: [files ? .fileURL : .string])
            pasteboard.clearContents()
            pasteboard.writeObjects([item])
        case "clipboard-read":
            // clipboard-read yes|no: whether anything read the contents clipboard-lazy put there.
            let reads = lazyClipboard?.reads ?? 0
            check(lazyClipboard != nil && (reads > 0) == (argument == "yes"), step, "\(reads) reads")
        case "trash-origin":
            // trash-origin <name> yes|no: whether Helm keeps where that item in the Trash came from.
            let answer = argument.split(separator: " ").last.map(String.init) ?? ""
            let name = String(argument.dropLast(answer.count + 1))
            let kept = window.dependencies.trashOrigins.records.contains { URL(fileURLWithPath: $0.trashedPath).lastPathComponent == name }
            check(kept == (answer == "yes"), step, kept ? "kept" : "not kept")
        case "file-lacks":
            // file-lacks <path>=<text>: the file doesn't mention the text. A missing file mentions nothing.
            let bits = argument.split(separator: "=", maxSplits: 1).map(String.init)
            let text = (try? String(contentsOfFile: bits[0], encoding: .utf8)) ?? ""
            check(bits.count == 2 && !text.contains(bits[1]), step, "it does")
        case "openwith-record":
            // openwith-record <app path> <file path>: keeps what opening the file with the app keeps, which is nothing
            // while Remember recent items is off. A scripted run opens no app.
            let bits = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard bits.count == 2 else { check(false, step, "usage"); return true }
            let found = await window.rememberOpeningForTesting(URL(fileURLWithPath: bits[1]), with: URL(fileURLWithPath: bits[0]))
            if !found { check(false, step, "no such file") }
        case "openwith-count":
            let count = window.dependencies.openWith.records.count
            check(count == Int(argument), step, "\(count) apps")
        case "restorable":
            // Nothing for macOS to bring back: neither browser windows nor Settings save state, and any state is read securely.
            // Settings is made if no step has made it yet, but never shown.
            app.makeSettingsWindowIfNeeded()
            let settings = app.settingsWindowForTesting
            let secure = app.applicationSupportsSecureRestorableState(NSApp)
            check(secure && window.window?.isRestorable == false && settings?.isRestorable == false, step,
                  "secure \(secure), window \(window.window?.isRestorable ?? true), Settings \(settings?.isRestorable ?? true)")
        default: return false
        }
        return true
    }
}
#endif
