import Foundation

/// How a state sits in the content area. Problems get a card of their own; an empty folder is just a quiet note.
public enum ContentStateStyle: String, Sendable {
    case empty, problem, waiting
}

/// What a content-area button does. The window carries it out.
public enum ContentStateAction: Hashable, Sendable {
    case tryAgain(Location)
    /// Shows how to give Helm access: the Full Disk Access guide, or the Settings row for the other panes.
    case grantAccess(PrivacyPane)
    /// Finder can always read the Trash, so it's the way in until Helm has Full Disk Access.
    case openTrashInFinder
    case goHome
}

public struct ContentStateButton: Hashable, Sendable {
    public let title: String
    public let action: ContentStateAction
    public let isPrimary: Bool
    public init(title: String, action: ContentStateAction, isPrimary: Bool = false) {
        self.title = title; self.action = action; self.isPrimary = isPrimary
    }
}

/// What the content area shows instead of a listing: why it's empty, or why it couldn't load and what to do.
public struct ContentState: Hashable, Sendable {
    public let style: ContentStateStyle
    /// An SF Symbol name.
    public let symbol: String
    public let title: String
    public let message: String?
    public let buttons: [ContentStateButton]
    public init(style: ContentStateStyle, symbol: String, title: String, message: String? = nil, buttons: [ContentStateButton] = []) {
        self.style = style; self.symbol = symbol; self.title = title; self.message = message; self.buttons = buttons
    }
}

/// Decides the content area's empty and failure states, so the words and buttons are tested without a window.
/// A refusal is explained by where it happened (`PrivacyAreas`), because the error code alone can't tell macOS
/// privacy from ordinary permissions. Evidence about the refused folder itself only ever narrows that down.
public enum ContentStatePresentation {
    /// The state for a tab, or nil while the listing itself is what to show.
    public static func state(for tab: TabState, home: URL, fullDiskAccess: PrivacyAccessStatus) -> ContentState? {
        let snapshot = tab.snapshot
        if let shown = failureOnShow(tab) {
            return failure(shown.error, attempted: shown.attempted, home: home, fullDiskAccess: fullDiskAccess,
                           evidence: evidence(about: shown.attempted, in: snapshot, home: home))
        }
        // The listing is on show when it loaded, or when a brief problem refreshing it left it standing.
        let listed: Bool
        switch snapshot.phase {
        case .ready: listed = true
        case .loading: listed = false
        case .failed(let error, let attempted): listed = keepsListing(plain(error), attempted: attempted, tab: tab)
        }
        guard listed, snapshot.rootCount == 0 else { return nil }
        if let search = tab.search { return search.isGathering ? nil : empty(.noResults) }
        switch tab.location {
        case .trash: return empty(.trash)
        case .recent: return empty(.recent)
        case .directory: return tab.isLoading ? nil : empty(.folder)
        }
    }

    // MARK: Which failure is on show

    /// The failure whose card stands in for the listing: why the place on show couldn't open, with the error read
    /// back into plain terms. Nil while the listing is what's on show: nothing failed, a load was cancelled, a search
    /// is up, the tab is on its way somewhere else, or a brief problem refreshing a listing left it standing. A
    /// reload of the folder a card covers, such as Show Hidden Files or an operation finishing, leaves the card up;
    /// Back from the card takes it down first (`TabAction.returnToListing`).
    public static func failureOnShow(_ tab: TabState) -> (error: LoadError, attempted: Location)? {
        guard tab.search == nil, case .failed(let raw, let attempted) = tab.snapshot.phase else { return nil }
        let error = plain(raw)
        guard error != .cancelled else { return nil }
        // Trying the same place again keeps its card up; going anywhere else lets that place decide.
        if let pending = tab.pendingNavigation, !samePlace(pending.target, attempted) { return nil }
        if keepsListing(error, attempted: attempted, tab: tab) { return nil }
        return (error, attempted)
    }

    /// Whether the listing underneath is hidden: a card stands in for it, or the tab is leaving a card for another
    /// place, whose own result decides what shows next. The old listing never comes back in between.
    public static func hidesListing(_ tab: TabState) -> Bool {
        if failureOnShow(tab) != nil { return true }
        guard tab.search == nil, case .failed(let raw, let attempted) = tab.snapshot.phase,
              let pending = tab.pendingNavigation, !samePlace(pending.target, attempted) else { return false }
        let error = plain(raw)
        return error != .cancelled && !keepsListing(error, attempted: attempted, tab: tab)
    }

    /// The place the content area is about: a place that couldn't open while its card is up, otherwise the tab's own.
    public static func placeOnShow(_ tab: TabState) -> Location {
        failureOnShow(tab)?.attempted ?? tab.location
    }

    /// The folder a card covers when the card is about another place, which is where Back goes from it.
    public static func coveredPlace(_ tab: TabState) -> Location? {
        guard tab.pendingNavigation == nil, let shown = failureOnShow(tab), !samePlace(shown.attempted, tab.location) else { return nil }
        return tab.location
    }

    /// The folder that holds a place, or nil for the Trash, Recent and the top of the disk.
    public static func enclosingFolder(of place: Location) -> Location? {
        guard case .directory(let url) = place else { return nil }
        let path = PathSpelling.standardPath(url)
        guard path != "/" else { return nil }
        return .directory(URL(fileURLWithPath: path, isDirectory: true).deletingLastPathComponent())
    }

    /// A problem refreshing the folder already on show, such as its watch stopping or a slow reply, leaves the
    /// listing standing; the status bar says what happened. A folder that's gone or refused is replaced by its card.
    static func keepsListing(_ error: LoadError, attempted: Location, tab: TabState) -> Bool {
        guard samePlace(attempted, tab.location) else { return false }
        switch error {
        // The monitor's own word: watching stopped, and the listing it was watching still stands.
        case .other("unavailable"): return true
        case .other, .timedOut: return tab.snapshot.rootCount > 0
        default: return false
        }
    }

    // MARK: The status bar and what waits for access

    /// What the status bar says while a failure touches the tab: why the place on show couldn't open, in place of
    /// an item count that belongs to the folder underneath, or a note beside a listing that couldn't refresh.
    /// Nil leaves the usual searching, gathering and idle states.
    public static func statusActivity(for tab: TabState, home: URL, fullDiskAccess: PrivacyAccessStatus) -> StatusActivity? {
        if let shown = failureOnShow(tab) {
            switch shown.error {
            case .permissionDenied: return .denied
            case .timedOut:
                return .unavailable(waitsOnMacOS(shown.attempted, home: home, fullDiskAccess: fullDiskAccess) ? "Waiting for permission" : "Not responding")
            case .notFound: return .unavailable("Not found")
            case .volumeUnmounted: return .unavailable("Disk disconnected")
            case .notIndexed: return .unavailable("Not indexed")
            case .other: return .unavailable("Couldn’t open")
            case .cancelled: return nil
            }
        }
        // A folder opened in place that couldn't be read closed again: the bar says why, in the words its own card
        // would use, beside the count.
        if tab.search == nil, let problem = tab.folderProblem {
            let place = Location.directory(problem.url)
            if let card = failure(problem.error, attempted: place, home: home, fullDiskAccess: fullDiskAccess,
                                  evidence: evidence(about: place, in: tab.snapshot, home: home)) {
                return .working(card.title)
            }
        }
        guard !tab.isLoading, tab.search == nil, case .failed(let raw, let attempted) = tab.snapshot.phase else { return nil }
        let error = plain(raw)
        guard keepsListing(error, attempted: attempted, tab: tab) else { return nil }
        return .working(error == .timedOut ? "Not responding" : "Couldn’t refresh")
    }

    /// Whether the tab shows a place that macOS privacy refused, or one whose read timed out while macOS may have
    /// been asking about it. Access to those can arrive later, so they're tried again when Helm comes back to the
    /// front, and reopen there after a quit. Ordinary permissions and missing folders don't change that way.
    public static func isBlockedByPrivacy(_ tab: TabState, home: URL, fullDiskAccess: PrivacyAccessStatus) -> Bool {
        guard let shown = failureOnShow(tab) else { return false }
        switch shown.error {
        case .timedOut:
            return waitsOnMacOS(shown.attempted, home: home, fullDiskAccess: fullDiskAccess)
        case .permissionDenied:
            // Outside the folders macOS is known to guard, an error code alone doesn't make it privacy (P-268).
            guard let area = PrivacyAreas.area(for: shown.attempted, home: home) ?? PrivacyAreas.disk(for: shown.attempted) else { return false }
            // Helm has Full Disk Access in this very run, so its areas refuse for reasons access won't change.
            if fullDiskAccess == .granted && area.isOpenedByFullDiskAccess { return false }
            switch evidence(about: shown.attempted, in: tab.snapshot, home: home) {
            case .ownership, .areaIsReadable: return false
            case .privacy, .none: return true
            }
        default:
            return false
        }
    }

    /// Where a tab should reopen: a place macOS refused, so quitting and reopening after giving Helm access
    /// lands back there instead of on the folder before.
    public static func sessionLocation(for tab: TabState, home: URL, fullDiskAccess: PrivacyAccessStatus) -> Location {
        guard isBlockedByPrivacy(tab, home: home, fullDiskAccess: fullDiskAccess), let shown = failureOnShow(tab) else { return tab.location }
        return shown.attempted
    }

    /// A read that timed out in a folder macOS asks about is most likely waiting on that question. Not with Full
    /// Disk Access on, which needs no asking, and not for a cloud provider, which is just as likely slow or offline.
    static func waitsOnMacOS(_ attempted: Location, home: URL, fullDiskAccess: PrivacyAccessStatus) -> Bool {
        guard fullDiskAccess != .granted, let area = PrivacyAreas.area(for: attempted, home: home) else { return false }
        return area.asksFirst && area.kind != .cloudFiles
    }

    /// The folder macOS's question is about when it asks before letting Helm into a place: the guarded folder as a
    /// whole, such as Documents for Documents › Reports, or, where each folder inside is asked about on its own, the
    /// one holding the place. Nil outside the folders macOS guards.
    static func askedAbout(_ place: Location, home: URL) -> Location? {
        guard case .directory(let url) = place, let area = PrivacyAreas.area(for: place, home: home) else { return nil }
        guard area.guardsEachChild else { return .directory(area.root) }
        let depth = URL(fileURLWithPath: PathSpelling.standardPath(area.root)).pathComponents.count
        let components = URL(fileURLWithPath: PathSpelling.standardPath(url)).pathComponents
        guard components.count > depth else { return .directory(area.root) }
        return .directory(area.root.appendingPathComponent(components[depth], isDirectory: true))
    }

    // MARK: Words and buttons

    /// What Helm knows about a refused folder beyond its path.
    public enum RefusalEvidence: Sendable, Equatable {
        case none
        /// Helm just listed another folder in the same guarded area, so macOS isn't what's refusing.
        case areaIsReadable
        /// The folder's own listing entry says ordinary permissions refuse it (EACCES), not macOS privacy.
        case ownership
        /// The folder's own listing entry says macOS refused it (EPERM). Inside a guarded area that's privacy;
        /// elsewhere it only suggests it, so it changes the words and nothing else.
        case privacy
    }

    public enum EmptyKind: Sendable { case folder, trash, recent, noResults }

    public static func empty(_ kind: EmptyKind) -> ContentState {
        switch kind {
        case .folder: return ContentState(style: .empty, symbol: "folder", title: "Folder is empty")
        case .trash: return ContentState(style: .empty, symbol: "trash", title: "Trash is empty")
        case .recent: return ContentState(style: .empty, symbol: "clock", title: "No recent items")
        case .noResults: return ContentState(style: .empty, symbol: "magnifyingglass", title: "No results")
        }
    }

    public static func failure(_ raw: LoadError, attempted: Location, home: URL, fullDiskAccess: PrivacyAccessStatus,
                               evidence: RefusalEvidence = .none) -> ContentState? {
        let name = displayName(attempted, home: home)
        let retry = ContentStateButton(title: "Try Again", action: .tryAgain(attempted))
        switch plain(raw) {
        case .cancelled:
            return nil
        case .permissionDenied:
            return refusal(attempted: attempted, name: name, home: home, fullDiskAccess: fullDiskAccess, evidence: evidence)
        case .timedOut:
            if waitsOnMacOS(attempted, home: home, fullDiskAccess: fullDiskAccess) {
                // macOS asks about the folder it guards, not the one inside it that was opened, so the card names the
                // same folder as macOS's own question.
                let asked = askedAbout(attempted, home: home).map { displayName($0, home: home) } ?? name
                return ContentState(style: .waiting, symbol: "hand.raised", title: "Waiting for permission",
                                    message: "macOS may be asking whether Helm can open \(asked). Answer its question and Helm will carry on.",
                                    buttons: [retry])
            }
            if PrivacyAreas.area(for: attempted, home: home)?.asksFirst == true {
                // A cloud provider, or a folder that needs no asking now: slow or offline rather than a disk unplugged.
                return ContentState(style: .problem, symbol: "clock.badge.exclamationmark", title: "\(capitalized(name)) isn’t responding",
                                    message: "It may be busy or offline. Try again in a moment.", buttons: [primary(retry)])
            }
            return ContentState(style: .problem, symbol: "externaldrive.badge.exclamationmark",
                                title: "The disk holding \(name) isn’t responding",
                                message: "Check that it’s still connected, then try again.", buttons: [primary(retry)])
        case .notFound:
            return ContentState(style: .problem, symbol: "questionmark.folder", title: "\(capitalized(name)) no longer exists",
                                message: "It may have been moved, renamed or deleted.",
                                buttons: [ContentStateButton(title: "Go to Home", action: .goHome, isPrimary: true)])
        case .volumeUnmounted:
            return ContentState(style: .problem, symbol: "externaldrive.badge.xmark", title: "The disk holding \(name) was disconnected",
                                message: "Reconnect it, then try again.",
                                buttons: [primary(retry), ContentStateButton(title: "Go to Home", action: .goHome)])
        case .notIndexed:
            return ContentState(style: .problem, symbol: "magnifyingglass", title: "This location isn’t indexed by Spotlight",
                                message: "Try searching the folder you’re in instead.")
        case .other(let message):
            return ContentState(style: .problem, symbol: "exclamationmark.triangle", title: "Helm couldn’t open \(name)",
                                message: readable(message), buttons: [primary(retry)])
        }
    }

    private static func refusal(attempted: Location, name: String, home: URL, fullDiskAccess: PrivacyAccessStatus,
                                evidence: RefusalEvidence) -> ContentState {
        let retry = ContentStateButton(title: "Try Again", action: .tryAgain(attempted))
        let grant = { (pane: PrivacyPane) in ContentStateButton(title: "Grant Access…", action: .grantAccess(pane), isPrimary: true) }
        let finder = ContentStateButton(title: "Open in Finder", action: .openTrashInFinder)
        let granted = fullDiskAccess == .granted
        // Full Disk Access reads as on only after Helm opened a guarded folder in this very run, so it's in effect:
        // reopening Helm wouldn't change anything, and these words don't suggest it.
        let ownership = { (message: String) in
            ContentState(style: .problem, symbol: "lock", title: "You don’t have permission to see inside \(name)",
                         message: message, buttons: [primary(retry)])
        }
        // The Trash has no listing entry of its own, so only its path speaks for it.
        if attempted == .trash {
            if granted {
                return ContentState(style: .problem, symbol: "trash.slash", title: "Helm can’t show the Trash",
                                    message: "Helm has Full Disk Access, so the Trash’s own permissions are keeping it out. Finder can still show it.",
                                    buttons: [primary(retry), finder])
            }
            return ContentState(style: .problem, symbol: "trash.slash", title: "Helm can’t show the Trash",
                                message: "Only apps with Full Disk Access can look inside the Trash.",
                                buttons: [grant(.fullDiskAccess), finder, retry])
        }
        let area = PrivacyAreas.area(for: attempted, home: home) ?? PrivacyAreas.disk(for: attempted)
        switch evidence {
        case .ownership, .areaIsReadable:
            // Ordinary permissions: the folder's owner decides, and no Settings switch would change that.
            return ownership("Its owner or its permissions don’t allow it.")
        case .privacy where area == nil:
            // An EPERM outside the folders macOS is known to guard only suggests privacy: the words say so, and
            // nothing waits for access or reopens there (`isBlockedByPrivacy`).
            if granted {
                return ContentState(style: .problem, symbol: "lock.shield", title: "Helm can’t open \(name)",
                                    message: "macOS won’t let Helm in, even with Full Disk Access.", buttons: [primary(retry)])
            }
            return ContentState(style: .problem, symbol: "lock.shield", title: "Helm can’t open \(name)",
                                message: "macOS won’t let Helm in. If this folder holds another app’s data, Full Disk Access may help.",
                                buttons: [ContentStateButton(title: "Full Disk Access…", action: .grantAccess(.fullDiskAccess), isPrimary: true), retry])
        case .privacy, .none:
            break
        }
        guard let area else { return ownership("Its owner or its permissions don’t allow it.") }
        let title = "Helm can’t open \(name)"
        if granted {
            if area.isOpenedByFullDiskAccess {
                return ownership("Helm has Full Disk Access, so the folder’s owner or its permissions are likely what’s keeping it out.")
            }
            // These keep switches of their own, which Full Disk Access may not cover: point at the row itself.
            switch area.kind {
            case .cloudFiles:
                return ContentState(style: .problem, symbol: "lock.shield", title: title,
                                    message: "Helm has Full Disk Access, but macOS also asks about each cloud provider’s files. Allow Helm in Files & Folders.",
                                    buttons: [grant(.filesAndFolders), retry])
            case .photosLibrary:
                return ContentState(style: .problem, symbol: "lock.shield", title: title,
                                    message: "Helm has Full Disk Access, but macOS also guards your photo library. Allow Helm in Photos.",
                                    buttons: [grant(.photos), retry])
            default:
                return ContentState(style: .problem, symbol: "lock.shield", title: title,
                                    message: "Helm has Full Disk Access, but macOS also guards your TV and music libraries. Allow Helm in Media & Apple Music.",
                                    buttons: [grant(.media), retry])
            }
        }
        switch area.kind {
        case .trash, .protectedData, .otherAppsData:
            return ContentState(style: .problem, symbol: "lock.shield", title: title,
                                message: "macOS keeps this folder private. Give Helm Full Disk Access to see inside.",
                                buttons: [grant(.fullDiskAccess), retry])
        case .desktop, .documents, .downloads, .cloudFiles, .disk:
            return ContentState(style: .problem, symbol: "lock.shield", title: title,
                                message: "macOS hasn’t let Helm in yet. Allow it in Files & Folders, or give Helm Full Disk Access.",
                                buttons: [grant(.filesAndFolders), retry])
        case .mediaLibrary, .photosLibrary:
            let pane: PrivacyPane = area.kind == .photosLibrary ? .photos : .media
            return ContentState(style: .problem, symbol: "lock.shield", title: title,
                                message: "macOS keeps your \(area.kind == .photosLibrary ? "photo library" : "TV and music libraries") private. Allow Helm in \(pane.title), or give it Full Disk Access.",
                                buttons: [grant(pane), ContentStateButton(title: "Full Disk Access…", action: .grantAccess(.fullDiskAccess)), retry])
        }
    }

    /// Narrows a refusal down with what the tab already knows, without touching the disk: the refused folder's
    /// own entry if it was listed (opening it from its parent), or a successful listing elsewhere in the same area.
    public static func evidence(about attempted: Location, in snapshot: PresentationSnapshot, home: URL) -> RefusalEvidence {
        guard case .directory(let url) = attempted else { return .none }
        if let entry = snapshot.entry(ItemID(url: url)) ?? snapshot.sortedEntries.first(where: { sameFolder($0.url, url) }),
           !entry.isReadable {
            return entry.isPrivacyProtected ? .privacy : .ownership
        }
        // Listing a folder in the area shows macOS let Helm into it. That holds only where the area is guarded as a
        // whole, not where each app's container or each cloud provider's files are asked about on their own.
        if snapshot.rootCount > 0, !samePlace(snapshot.location, attempted),
           let target = PrivacyAreas.area(containing: url, home: home), !target.guardsEachChild,
           let listed = PrivacyAreas.area(for: snapshot.location, home: home), listed == target {
            return .areaIsReadable
        }
        return .none
    }

    // MARK: Plain errors and names

    /// Monitor and refresh problems reach a tab as the error's own name ("notFound"), sometimes wrapped in another
    /// ("other(\"timedOut\")"). Read back, they get the same card and words as a load that failed the same way.
    public static func plain(_ error: LoadError) -> LoadError {
        guard case .other(var text) = error else { return error }
        while text.hasPrefix("other(\""), text.hasSuffix("\")") { text = String(text.dropFirst(7).dropLast(2)) }
        switch text {
        case "notFound": return .notFound
        case "permissionDenied": return .permissionDenied
        case "timedOut": return .timedOut
        case "volumeUnmounted": return .volumeUnmounted
        default: return .other(text)
        }
    }

    /// A sentence is shown as it is. An error's own name or a system error dump isn't for reading, so it gets
    /// plain words instead.
    static func readable(_ message: String) -> String? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let head = text.prefix { $0 != "(" }
        let isName = head.first?.isLowercase == true && head.allSatisfy { $0.isLetter || $0.isNumber }
        if isName || text.hasPrefix("Error Domain=") { return "Something went wrong while reading it. Try again in a moment." }
        return text
    }

    /// Two spellings of one place, as navigation compares them.
    public static func samePlace(_ a: Location, _ b: Location) -> Bool {
        switch (a, b) {
        case (.trash, .trash), (.recent, .recent): return true
        case (.directory(let x), .directory(let y)): return PathSpelling.standardPath(x) == PathSpelling.standardPath(y)
        default: return false
        }
    }

    /// A place's name in quotes, as the path bar shows it: a cloud drive by its provider, not its folder's own name.
    static func displayName(_ location: Location, home: URL) -> String {
        switch location {
        case .trash: return "the Trash"
        case .recent: return "Recent"
        case .directory(let url):
            if url.path == "/" { return "“/”" }
            let parent = PathSpelling.standardPath(url.deletingLastPathComponent())
            let library = home.appendingPathComponent("Library", isDirectory: true)
            if parent == PathSpelling.standardPath(library.appendingPathComponent("CloudStorage", isDirectory: true)) {
                return "“\(CloudDriveNaming.provider(ofFolder: url.lastPathComponent))”"
            }
            if PathSpelling.standardPath(url) == PathSpelling.standardPath(library.appendingPathComponent("Mobile Documents/com~apple~CloudDocs", isDirectory: true)) {
                return "“iCloud Drive”"
            }
            return "“\(url.lastPathComponent)”"
        }
    }
    private static func capitalized(_ name: String) -> String { name.prefix(1).uppercased() + name.dropFirst() }
    private static func primary(_ button: ContentStateButton) -> ContentStateButton {
        ContentStateButton(title: button.title, action: button.action, isPrimary: true)
    }
    private static func sameFolder(_ a: URL, _ b: URL) -> Bool {
        PathSpelling.standardPath(a).lowercased() == PathSpelling.standardPath(b).lowercased()
    }
}
