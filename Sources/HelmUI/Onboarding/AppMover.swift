#if os(macOS)
import AppKit
import Darwin

/// Where this copy of Helm runs from, as far as moving it into Applications goes.
public enum AppPlacement: String, Sendable, Equatable {
    /// In an Applications folder: /Applications, ~/Applications, or any folder called Applications, such as one on
    /// another disk. Nothing to do.
    case applications
    /// On a read-only disk image, as when Helm is opened straight from the one it came on.
    case diskImage
    /// macOS runs a downloaded copy from a random read-only place until it's moved (App Translocation).
    case translocated
    /// Downloads, the Desktop, a project folder: anywhere else.
    case elsewhere
    /// Not an app bundle at all, as HelmDev isn't. There's nothing to move.
    case notAnApp
    /// A build Xcode or xcodebuild has just made, run where it was built. Moving it would copy it over the Helm
    /// that's installed, so it isn't offered.
    case developerBuild

    public var needsMove: Bool { self == .diskImage || self == .translocated || self == .elsewhere }
    /// Runs from a place that goes away: a disk image once it's ejected, or macOS's temporary copy after a restart.
    /// Nothing that remembers where Helm is, such as its Dock tile, should point here.
    public var isTemporary: Bool { self == .diskImage || self == .translocated }

    /// Decided from the bundle's path and what its volume says about itself, so it can be tested without a disk image.
    /// The path is compared as `BundlePath` spells it; `applicationFolders` are more folders that count, as the disk
    /// spells them once symlinks are resolved.
    public static func decide(bundlePath: String, home: String, isTranslocated: Bool, isOnReadOnlyVolume: Bool,
                              applicationFolders: [String] = []) -> AppPlacement {
        let path = BundlePath.normalized(bundlePath)
        guard path.hasSuffix(".app") else { return .notAnApp }
        if isTranslocated || path.contains("/apptranslocation/") { return .translocated }
        if path.hasPrefix("/volumes/") && isOnReadOnlyVolume { return .diskImage }
        let folders = path.split(separator: "/").dropLast().map(String.init)
        if BundlePath.isBuildFolder(folders) { return .developerBuild }
        let known = (["/Applications", home + "/Applications"] + applicationFolders).map(BundlePath.normalized)
        if known.contains(where: { path.hasPrefix($0 + "/") }) || folders.contains("applications") { return .applications }
        return .elsewhere
    }

    /// The copy at `bundle`. Only reads: the path with its symlinks resolved, the volume's read-only flag, and
    /// macOS's translocation check.
    public static func of(_ bundle: URL, home: URL) -> AppPlacement {
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        // ~/Applications may be a symlink to another disk, and Helm is then launched from where it points.
        let folders = [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications", isDirectory: true)]
            + FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .networkDomainMask, .systemDomainMask])
        let spellings = folders.flatMap { [$0.path, $0.resolvingSymlinksInPath().path] }
        return decide(bundlePath: bundle.resolvingSymlinksInPath().path, home: home.path, isTranslocated: isTranslocated(bundle),
                      isOnReadOnlyVolume: readOnly, applicationFolders: spellings)
    }

    /// Asks the Security framework, which keeps this call private, so it's looked up by name. Without it, the path decides.
    static func isTranslocated(_ url: URL) -> Bool {
        guard let security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return false }
        defer { dlclose(security) }
        guard let symbol = dlsym(security, "SecTranslocateIsTranslocatedURL") else { return false }
        // Boolean SecTranslocateIsTranslocatedURL(CFURLRef path, bool *isTranslocated, CFErrorRef *error)
        typealias Check = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> UInt8
        let check = unsafeBitCast(symbol, to: Check.self)
        var translocated = false
        return check(url as CFURL, &translocated, nil) != 0 && translocated
    }
}

/// One spelling for one place on disk, for comparing where apps are.
enum BundlePath {
    /// No doubled or trailing slash, without the Data volume's /System/Volumes/Data prefix (the same folders through
    /// a firmlink), and in lower case, as APFS compares names. Whoever reads the disk resolves symlinks first.
    static func normalized(_ path: String) -> String {
        var text = path.lowercased()
        while text.contains("//") { text = text.replacingOccurrences(of: "//", with: "/") }
        if text.count > 1, text.hasSuffix("/") { text.removeLast() }
        let firmlink = "/system/volumes/data"
        if text == firmlink { return "/" }
        if text.hasPrefix(firmlink + "/") { text.removeFirst(firmlink.count) }
        return text
    }

    /// Folders a build is made in: Xcode's DerivedData and Build/Products, xcodebuild's build/Release and build/Debug,
    /// and SwiftPM's .build. Names are already in lower case.
    static func isBuildFolder(_ folders: [String]) -> Bool {
        if folders.contains("deriveddata") || folders.contains(".build") { return true }
        return zip(folders, folders.dropFirst()).contains { folder, next in
            folder == "build" && (next == "products" || next == "debug" || next == "release"
                                  || next.hasPrefix("debug-") || next.hasPrefix("release-"))
        }
    }
}

/// How copying Helm into Applications went.
public enum AppMoveResult: Equatable, Sendable {
    case moved(URL)
    /// Asked whether to replace the Helm already there, and told no.
    case cancelled
    case failed(String)
}

/// What an app bundle says about itself, read from its Info.plist.
public struct AppBundleInfo: Equatable, Sendable {
    public var identifier: String?
    public var version: String?
    public var build: String?
    public init(identifier: String?, version: String? = nil, build: String? = nil) {
        self.identifier = identifier; self.version = version; self.build = build
    }

    /// Read straight from Contents/Info.plist: `Bundle` keeps what it read the first time, and the copy there may
    /// have changed since. Nil when there's no Info.plist to read, as for anything that isn't an app.
    public static func read(_ app: URL) -> AppBundleInfo? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        return AppBundleInfo(identifier: info["CFBundleIdentifier"] as? String, version: info["CFBundleShortVersionString"] as? String,
                             build: info["CFBundleVersion"] as? String)
    }

    /// "Helm 1.2 (45)", or less when the bundle doesn't say.
    public var name: String {
        switch (version, build) {
        case let (version?, build?) where version != build: return "Helm \(version) (\(build))"
        case let (version?, _): return "Helm \(version)"
        case let (nil, build?): return "Helm (\(build))"
        case (nil, nil): return "Helm"
        }
    }

    /// Whether this is a later Helm than `other`: by version, then build. Nil when either doesn't give a version.
    public func isNewer(than other: AppBundleInfo) -> Bool? {
        guard let mine = version, let theirs = other.version else { return nil }
        let byVersion = mine.compare(theirs, options: .numeric)
        if byVersion != .orderedSame { return byVersion == .orderedDescending }
        guard let mine = build, let theirs = other.build else { return false }
        return mine.compare(theirs, options: .numeric) == .orderedDescending
    }
}

/// What to do when Applications already has something called Helm.app.
public enum ReplaceDecision: Equatable, Sendable {
    /// It isn't this app, so it's left alone and the move fails with this message.
    case refuse(String)
    /// It's Helm. Ask, naming both versions. Replace is the default button unless the one there is newer.
    case ask(title: String, detail: String, replaceIsDefault: Bool)

    public static func decide(existing: AppBundleInfo?, incoming: AppBundleInfo, folderName: String) -> ReplaceDecision {
        guard let existing, let identifier = incoming.identifier, existing.identifier == identifier else {
            return .refuse("Another app called Helm is in \(folderName), so rename or move it first.")
        }
        // One sentence for every case: the title says when the Helm there is newer, and two identical names say it's
        // the same version.
        let detail = "\(existing.name) goes to the Trash, and \(incoming.name) takes its place."
        if existing.isNewer(than: incoming) == true {
            return .ask(title: "Replace a newer Helm?", detail: detail, replaceIsDefault: false)
        }
        return .ask(title: "Replace the Helm in \(folderName)?", detail: detail, replaceIsDefault: true)
    }
}

/// Moving Helm into Applications, behind a seam: fixture runs and tests use a stand-in that copies nothing and never quits.
@MainActor public protocol AppMoving: AnyObject {
    var placement: AppPlacement { get }
    /// Copies Helm into Applications. Asks first when that would replace a Helm already there, and refuses when
    /// what's there isn't Helm.
    func moveToApplications() async -> AppMoveResult
    /// Whether a copy made earlier is still there, so trying again only has to reopen it.
    func hasCopy(at copy: URL) -> Bool
    /// Quits this Helm and opens the copy once it has, which reopens the welcome window and carries on with these rows.
    /// A quit that goes through ends the process, so this returns only while this Helm keeps running: true if it's on
    /// its way out, false when the quit was cancelled or the copy couldn't be opened.
    func relaunch(from copy: URL, continuing rows: [SetupRow]) async -> Bool
}

/// Copies an app bundle into the first Applications folder that will take it, and lifts the quarantine from the copy.
/// Only file work: no questions, no relaunch. Tests point it at folders of their own, and at a Trash of their own.
public struct AppBundleCopier: Sendable {
    public let source: URL
    /// In order of preference.
    public let folders: [URL]
    /// What the copy is called, whatever the download was: "Helm 2.app" still goes in as Helm.app, so it's checked
    /// against the Helm already there rather than landing beside it.
    public let name: String
    /// Moves a copy that's being replaced to the Trash and says where it went. There's no default: the app passes
    /// `moveToTrash`, and tests a folder of their own, so a test can never reach the person's own Trash.
    public let trash: @Sendable (URL) throws -> URL?

    public init(source: URL, folders: [URL], name: String = "Helm.app", trash: @escaping @Sendable (URL) throws -> URL?) {
        self.source = source; self.folders = folders; self.name = name; self.trash = trash
    }

    /// /Applications, then ~/Applications for someone who can't write to it.
    public static func standardFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true), home.appendingPathComponent("Applications", isDirectory: true)]
    }

    public static let quarantine = "com.apple.quarantine"

    /// The person's own Trash, as Finder's Move to Trash does it.
    public static func moveToTrash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// Where the copy goes: into the first folder that can be written to, or that's missing and can be made.
    public func target() -> URL? {
        let manager = FileManager.default
        for folder in folders {
            var isFolder: ObjCBool = false
            let exists = manager.fileExists(atPath: folder.path, isDirectory: &isFolder)
            if exists ? isFolder.boolValue && manager.isWritableFile(atPath: folder.path)
                      : manager.isWritableFile(atPath: folder.deletingLastPathComponent().path) {
                return folder.appendingPathComponent(name, isDirectory: true)
            }
        }
        return nil
    }

    /// Something is at `url`, even a symlink that points nowhere.
    public static func exists(_ url: URL) -> Bool { (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil }

    /// The same file on disk, however its path is spelled.
    public static func isSameItem(_ one: URL, _ other: URL) -> Bool {
        guard let first = (try? one.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier,
              let second = (try? other.resourceValues(forKeys: [.fileResourceIdentifierKey]))?.fileResourceIdentifier else { return false }
        return first.isEqual(second)
    }

    /// Copies the app to `target`. A copy that's already there is replaced: whoever calls this has asked first. It goes
    /// to the Trash, never straight out of existence, and only once the new copy is ready beside it, so a failed copy
    /// leaves the old one as it was.
    public func copy(to target: URL) -> AppMoveResult {
        let manager = FileManager.default
        let folder = target.deletingLastPathComponent().path
        do {
            try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard Self.exists(target) else {
                do { try manager.copyItem(at: source, to: target) } catch {
                    try? manager.removeItem(at: target)
                    throw error
                }
                Self.removeQuarantine(under: target)
                return .moved(target)
            }
            if Self.isSameItem(source, target) { return .failed("Helm is already in \(folder).") }
            let staging = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
            defer { try? manager.removeItem(at: staging) }
            let staged = staging.appendingPathComponent(target.lastPathComponent, isDirectory: true)
            try manager.copyItem(at: source, to: staged)
            Self.removeQuarantine(under: staged)
            let trashed: URL?
            do { trashed = try trash(target) } catch {
                return .failed("The Helm in \(folder) couldn’t be moved to the Trash, so nothing changed: \(error.localizedDescription)")
            }
            do { try manager.moveItem(at: staged, to: target) } catch {
                // Back from the Trash, so Applications isn't left without Helm.
                if let trashed { try? manager.moveItem(at: trashed, to: target) }
                throw error
            }
            return .moved(target)
        } catch {
            return .failed("Helm couldn’t be copied to \(folder): \(error.localizedDescription)")
        }
    }

    /// The person already said yes to opening Helm once, so the copy shouldn't ask again. Only the quarantine flag goes;
    /// every other attribute stays.
    public static func removeQuarantine(under root: URL) {
        removexattr(root.path, quarantine, XATTR_NOFOLLOW)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return }
        for case let url as URL in walker { removexattr(url.path, quarantine, XATTR_NOFOLLOW) }
    }
}

/// The real thing: copies the running Helm.app, then quits and opens the copy.
@MainActor public final class SystemAppMover: AppMoving {
    private let bundle: Bundle
    private var decided: AppPlacement?
    public init(bundle: Bundle = .main) { self.bundle = bundle }

    public var placement: AppPlacement {
        if let decided { return decided }
        let value = AppPlacement.of(bundle.bundleURL, home: FileManager.default.homeDirectoryForCurrentUser)
        decided = value
        return value
    }

    public func moveToApplications() async -> AppMoveResult {
        let copier = AppBundleCopier(source: bundle.bundleURL, folders: AppBundleCopier.standardFolders()) { try AppBundleCopier.moveToTrash($0) }
        guard let target = copier.target() else {
            // Finder can ask for an administrator's password; Helm doesn't.
            return .failed("Helm can’t write to Applications, so drag it there in Finder.")
        }
        if AppBundleCopier.exists(target) {
            let folderName = target.deletingLastPathComponent().lastPathComponent
            if AppBundleCopier.isSameItem(bundle.bundleURL, target) { return .failed("Helm is already in \(folderName).") }
            let incoming = AppBundleInfo.read(bundle.bundleURL) ?? AppBundleInfo(identifier: bundle.bundleIdentifier)
            switch ReplaceDecision.decide(existing: AppBundleInfo.read(target), incoming: incoming, folderName: folderName) {
            case .refuse(let message): return .failed(message)
            case .ask(let title, let detail, let replaceIsDefault):
                if !Self.askToReplace(title: title, detail: detail, replaceIsDefault: replaceIsDefault) { return .cancelled }
            }
        }
        return await Task.detached(priority: .userInitiated) { copier.copy(to: target) }.value
    }

    public func hasCopy(at copy: URL) -> Bool { AppBundleCopier.exists(copy) }

    private static func askToReplace(title: String, detail: String, replaceIsDefault: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Cancel")
        if !replaceIsDefault {
            // Return keeps the newer Helm.
            alert.buttons[0].keyEquivalent = ""
            alert.buttons[1].keyEquivalent = "\r"
        }
        return alert.runModal() == .alertFirstButtonReturn
    }

    public func relaunch(from copy: URL, continuing rows: [SetupRow]) async -> Bool {
        // A small shell waits for this Helm to quit, however long saving and file operations take, then opens the copy
        // with the flag that carries on. -n opens a new one even if an older Helm is still running from the copy that
        // was just replaced; without it, `open` would only bring that one forward and drop the flag.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; "
            + "exec /usr/bin/open -n \"$0\" --args \(SetupRow.continueFlag) \"$1\""
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", script, copy.path, SetupRow.flagValue(rows)]
        do { try waiter.run() } catch { return false }
        await Self.quit()
        // Still running, so the quit was cancelled (saving failed and the person chose Cancel, say): stop waiting.
        waiter.terminate()
        return false
    }

    /// Asks Helm to quit, and returns only if it doesn't. Quitting saves first, and saving needs the main actor, so
    /// the quit starts from a run loop block: one started inside a task holds the main actor and waits forever.
    static func quit() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.perform(inModes: [.default, .modalPanel]) {
                MainActor.assumeIsolated { NSApp.terminate(nil) }
                // A quit that goes through never gets here.
                continuation.resume()
            }
            // A queued block doesn't wake the run loop by itself.
            CFRunLoopWakeUp(RunLoop.main.getCFRunLoop())
        }
    }
}

/// A fixture run's and a test's stand-in: a placement that's set by hand, and a record of what Helm asked for.
/// Nothing is copied and nothing quits.
@MainActor public final class MemoryAppMover: AppMoving {
    public var placement: AppPlacement
    public var result: AppMoveResult
    /// What a relaunch answers. Nothing really quits, so by default it answers as a quit that was cancelled.
    public var quitsOnRelaunch = false
    public private(set) var moves = 0
    public private(set) var relaunches: [[SetupRow]] = []
    public init(placement: AppPlacement = .applications,
                result: AppMoveResult = .moved(URL(fileURLWithPath: "/Applications/Helm.app", isDirectory: true))) {
        self.placement = placement; self.result = result
    }
    public func moveToApplications() async -> AppMoveResult { moves += 1; return result }
    /// Only the copy it said it made, and only once it has made one: nothing on disk is looked at.
    public func hasCopy(at copy: URL) -> Bool { moves > 0 && result == .moved(copy) }
    public func relaunch(from copy: URL, continuing rows: [SetupRow]) async -> Bool {
        relaunches.append(rows)
        return quitsOnRelaunch
    }
}
#endif
