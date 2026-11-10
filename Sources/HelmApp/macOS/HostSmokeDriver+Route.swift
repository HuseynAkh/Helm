#if os(macOS)
import AppKit
import HelmCore
import HelmUI

/// Smoke verbs for requests to the file viewer, and who shows them: Helm, or Finder for what started in Finder.
/// A fixture run hands Finder's share to a stand-in, so Finder, Archive Utility and DiskImageMounter are never involved.
extension HostSmokeDriver {
    private static var windowsBeforeRequest = 0

    static func performRouteVerb(_ verb: String, _ argument: String, step: String,
                                 window: BrowserWindowController, app: AppController) async -> Bool {
        switch verb {
        case "viewer-request":
            // "<open|reveal|reopen> <sender bundle id|none> [path|path…]": a request as macOS delivers it, from that app.
            let bits = argument.split(separator: " ", maxSplits: 2).map(String.init)
            guard bits.count >= 2, let request = viewerRequest(bits[0], items: bits.count > 2 ? bits[2] : "") else {
                check(false, step, "usage"); return true
            }
            windowsBeforeRequest = app.allWindows.count
            app.receive(request, from: bits[1] == "none" ? nil : bits[1])
            await wait(seconds: 0.9)
        case "viewer-event":
            // "<odoc|mvis|rapp> [from <bundle id>] [path|path…]": a real Apple Event, dispatched through Helm's event
            // handlers as one from another app is, so AppKit's open and reopen handlers and Helm's reveal handler each
            // take theirs. Sending it to Helm's own process instead times out: AppKit holds an open-documents event it
            // sent itself. An event built here names no sender, so "from" stands in for the one macOS would fill in;
            // it's read through the same lookup, and only while the event is being handled.
            var bits = argument.split(separator: " ", maxSplits: 1).map(String.init)
            var sender: String?
            if bits.count > 1, bits[1].hasPrefix("from ") {
                let rest = bits[1].dropFirst(5).split(separator: " ", maxSplits: 1).map(String.init)
                sender = rest.first
                bits = [bits[0]] + rest.dropFirst()
            }
            guard let event = appleEvent(bits.first ?? "", items: bits.count > 1 ? bits[1] : ""), let raw = event.aeDesc else {
                check(false, step, "usage"); return true
            }
            windowsBeforeRequest = app.allWindows.count
            var reply = AEDesc()
            AEInitializeDesc(&reply)
            var refCon: UInt8 = 0
            app.eventSenderForTesting = sender
            let status = withUnsafeMutablePointer(to: &refCon) { pointer in
                NSAppleEventManager.shared().dispatchRawAppleEvent(raw, withRawReply: &reply, handlerRefCon: UnsafeMutableRawPointer(pointer))
            }
            app.eventSenderForTesting = nil
            AEDisposeDesc(&reply)
            if status != noErr { check(false, step, "status \(status)") }
            await wait(seconds: 0.9)
        case "windows-unchanged":
            check(app.allWindows.count == windowsBeforeRequest, step, "count \(app.allWindows.count), was \(windowsBeforeRequest)")
        case "handoff":
            // "<helper bundle id> <path>": as Helm handing an archive to that helper, without starting it.
            let bits = argument.split(separator: " ", maxSplits: 1).map(String.init)
            guard bits.count == 2 else { check(false, step, "usage"); return true }
            window.dependencies.handoffs.record([URL(fileURLWithPath: bits[1])], helper: bits[0]) { window.namesListed(in: $0) }
        case "make-folder":
            // What Archive Utility leaves next to an archive it expands.
            do { try FileManager.default.createDirectory(atPath: argument, withIntermediateDirectories: true) }
            catch { check(false, step, "\(error)") }
            await wait(seconds: 0.5)
        case "finder-count":
            check(app.finderShownForTesting.count == Int(argument), step, "count \(app.finderShownForTesting.count)")
        case "finder-last":
            // "front" when Finder was only brought forward, or the folders it was asked to open, "|"-separated.
            let last = app.finderShownForTesting.last
            let shown = last.map { $0.isEmpty ? "front" : $0.map(\.path).joined(separator: "|") } ?? "nothing"
            let wanted = argument == "front" ? argument
                : argument.split(separator: "|").map { URL(fileURLWithPath: String($0)).path }.joined(separator: "|")
            check(shown == wanted, step, shown)
        default:
            return false
        }
        return true
    }

    private static func viewerRequest(_ kind: String, items: String) -> ViewerRequest? {
        let urls = items.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
        switch kind {
        case "open": return .open(urls)
        case "reveal": return .reveal(urls)
        case "reopen": return .reopen
        default: return nil
        }
    }

    private static func appleEvent(_ kind: String, items: String) -> NSAppleEventDescriptor? {
        let ids: (AEEventClass, AEEventID)
        switch kind {
        case "odoc": ids = (AEEventClass(kCoreEventClass), AEEventID(kAEOpenDocuments))
        case "mvis": ids = (AEEventClass(kAEMiscStandards), AEEventID(kAEMakeObjectsVisible))
        case "rapp": ids = (AEEventClass(kCoreEventClass), AEEventID(kAEReopenApplication))
        default: return nil
        }
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: ids.0, eventID: ids.1, targetDescriptor: .currentProcess(),
                                                      returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        let urls = items.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
        if !urls.isEmpty {
            let list = NSAppleEventDescriptor.list()
            for (index, url) in urls.enumerated() { list.insert(NSAppleEventDescriptor(fileURL: url), at: index + 1) }
            event.setParam(list, forKeyword: keyDirectObject)
        }
        return event
    }
}
#endif
