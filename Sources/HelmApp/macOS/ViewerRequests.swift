#if os(macOS)
import AppKit
import Darwin
import HelmCore

/// Reads what macOS sends the file viewer. Probed on macOS 26 (docs/handoff/DEFAULT_FILE_MANAGER.md): NSWorkspace's
/// Show in Finder arrives as an open-documents event naming the items, a reveal of no items as a reopen, and an explicit
/// reveal would be a make-objects-visible event. The sender's process number comes with each one.
enum ViewerEvent {
    /// The request an event makes, or nil for any other event.
    static func request(from event: NSAppleEventDescriptor) -> ViewerRequest? {
        let kind = (event.eventClass, event.eventID)
        if kind == (AEEventClass(kCoreEventClass), AEEventID(kAEOpenDocuments)) { return .open(items(in: event)) }
        if kind == (AEEventClass(kAEMiscStandards), AEEventID(kAEMakeObjectsVisible)) { return .reveal(items(in: event)) }
        if kind == (AEEventClass(kCoreEventClass), AEEventID(kAEReopenApplication)) { return .reopen }
        return nil
    }

    /// The items an event names: file URLs, aliases or bookmarks, alone or in a list.
    static func items(in event: NSAppleEventDescriptor) -> [URL] {
        guard let direct = event.paramDescriptor(forKeyword: keyDirectObject) else { return [] }
        return urls(in: direct)
    }

    static func urls(in descriptor: NSAppleEventDescriptor) -> [URL] {
        if descriptor.descriptorType == typeAEList {
            guard descriptor.numberOfItems > 0 else { return [] }
            return (1...descriptor.numberOfItems).compactMap { descriptor.atIndex($0) }.flatMap { urls(in: $0) }
        }
        if textTypes.contains(descriptor.descriptorType) {
            // A path or a file URL as text, as a script might send one. macOS's own coercion would read the text
            // as an old colon-separated path, so it's read here instead.
            guard let text = descriptor.stringValue else { return [] }
            if text.hasPrefix("/") { return [URL(fileURLWithPath: text)] }
            if let url = URL(string: text), url.isFileURL { return [url] }
            return []
        }
        // A file URL, an alias or a bookmark.
        if let url = descriptor.fileURLValue, url.isFileURL { return [url] }
        if let url = descriptor.coerce(toDescriptorType: DescType(typeFileURL))?.fileURLValue, url.isFileURL { return [url] }
        return []
    }

    private static let textTypes: Set<DescType> = Set(["utf8", "utxt", "TEXT", "ut16", "STXT", "itxt"].map { code in
        code.utf8.reduce(DescType(0)) { $0 << 8 | DescType($1) }
    })

    /// The process that sent the event, unless it's Helm itself: the open-application event of a launch names Helm.
    static func senderPID(of event: NSAppleEventDescriptor) -> pid_t? {
        guard let descriptor = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr)) else { return nil }
        let pid = descriptor.int32Value
        return pid > 0 && pid != getpid() ? pid : nil
    }
}

/// Which app sent a request, by bundle identifier. Archive Utility sends its last request as it quits, so the process
/// numbers of Finder and its helpers are kept for a minute after they've gone.
@MainActor final class SenderDirectory {
    var running: (pid_t) -> String? = { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }
    var executable: (pid_t) -> String? = { SenderDirectory.executablePath(of: $0) }
    /// Called with a helper's bundle identifier when it quits.
    var helperQuit: ((String) -> Void)?
    private var known: [pid_t: String] = [:]
    private var gone: [pid_t: (identifier: String, date: Date)] = [:]
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        for app in NSWorkspace.shared.runningApplications where FinderFamily.isMember(app.bundleIdentifier) {
            known[app.processIdentifier] = app.bundleIdentifier
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let identifier = app.bundleIdentifier, FinderFamily.isMember(identifier) else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.known[pid] = identifier }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let identifier = app.bundleIdentifier, FinderFamily.isMember(identifier) else { return }
            let pid = app.processIdentifier
            MainActor.assumeIsolated { self?.forget(pid, identifier: identifier) }
        })
    }

    func forget(_ pid: pid_t, identifier: String) {
        let now = Date()
        known[pid] = nil
        gone = gone.filter { now.timeIntervalSince($0.value.date) < 60 }
        gone[pid] = (identifier, now)
        if FinderFamily.isHelper(identifier) { helperQuit?(identifier) }
    }

    func identifier(of pid: pid_t?) -> String? {
        guard let pid else { return nil }
        if let identifier = running(pid) ?? known[pid] ?? gone[pid]?.identifier { return identifier }
        return executable(pid).flatMap(Self.bundleIdentifier(enclosing:))
    }

    nonisolated static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        return length > 0 ? String(cString: buffer) : nil
    }

    /// The bundle identifier of the app an executable sits in.
    nonisolated static func bundleIdentifier(enclosing executable: String) -> String? {
        var url = URL(fileURLWithPath: executable)
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app" { return Bundle(url: url)?.bundleIdentifier }
            url.deleteLastPathComponent()
        }
        return nil
    }
}

/// Shows something in Finder instead of Helm. It goes through Launch Services, never an Apple Event to Finder, which
/// would need Automation permission.
@MainActor protocol FinderHandingBack: AnyObject {
    /// Opens each folder in Finder and brings Finder forward. With none, only brings Finder forward.
    func show(folders: [URL])
}

@MainActor final class SystemFinderHandback: FinderHandingBack {
    static let finderURL = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")

    func show(folders: [URL]) {
        // The request brought Helm to the front; Helm hands that over to Finder.
        NSApp.yieldActivation(toApplicationWithBundleIdentifier: FinderFamily.finder)
        guard !folders.isEmpty else {
            // As Archive Utility brings Finder forward when Finder is the file viewer: no new window.
            if let finder = NSRunningApplication.runningApplications(withBundleIdentifier: FinderFamily.finder).first {
                _ = finder.activate(from: .current, options: [])
            }
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: FinderFamily.finder) ?? Self.finderURL
        NSWorkspace.shared.open(folders, withApplicationAt: finder, configuration: configuration, completionHandler: nil)
    }
}

/// Fixture runs and tests: notes what would have gone to Finder. Finder itself is never involved.
@MainActor final class RecordingFinderHandback: FinderHandingBack {
    private(set) var shown: [[URL]] = []
    func show(folders: [URL]) { shown.append(folders) }
}
#endif
