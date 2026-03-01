import Foundation
import AppKit

/// Manages clipboard operations for file cut/copy/paste
@MainActor
class ClipboardService {

    static let shared = ClipboardService()

    /// Whether the current clipboard operation is a "cut" (move) vs "copy"
    private(set) var isCut: Bool = false

    /// URLs currently on the clipboard
    private(set) var clipboardURLs: [URL] = []

    private init() {}

    func copyFiles(_ urls: [URL]) {
        isCut = false
        clipboardURLs = urls
        writeToPasteboard(urls)
    }

    func cutFiles(_ urls: [URL]) {
        isCut = true
        clipboardURLs = urls
        writeToPasteboard(urls)
    }

    func pasteFiles() -> (urls: [URL], isCut: Bool)? {
        // Try reading from our internal state first
        if !clipboardURLs.isEmpty {
            let result = (urls: clipboardURLs, isCut: isCut)
            if isCut {
                // Clear after cut-paste
                clipboardURLs = []
                isCut = false
            }
            return result
        }

        // Fall back to system pasteboard
        guard let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
              !urls.isEmpty else {
            return nil
        }

        return (urls: urls, isCut: false)
    }

    func hasItems() -> Bool {
        !clipboardURLs.isEmpty || NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: nil)
    }

    private func writeToPasteboard(_ urls: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }
}
