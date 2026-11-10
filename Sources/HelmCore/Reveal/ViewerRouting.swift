import Foundation

/// Finder and the apps that do Finder's work for it. When Helm is the file viewer, a request one of the helpers sends
/// started in Finder, unless Helm handed that helper the item itself. Finder's own requests are ones you sent to Helm.
/// docs/handoff/DEFAULT_FILE_MANAGER.md has the probes.
public enum FinderFamily {
    public static let finder = "com.apple.finder"
    /// Archive Utility shows what it expanded through the file viewer, then brings the file viewer forward as it quits.
    /// DiskImageMounter asks Finder directly today. It's listed so a later macOS that changes that is still covered.
    public static let helpers: Set<String> = ["com.apple.archiveutility", "com.apple.diskimagemounter"]

    /// Bundle identifiers compare without case, as Launch Services compares them.
    public static func isFinder(_ identifier: String?) -> Bool { identifier?.lowercased() == finder }
    public static func isHelper(_ identifier: String?) -> Bool { identifier.map { helpers.contains($0.lowercased()) } ?? false }
    public static func isMember(_ identifier: String?) -> Bool { isFinder(identifier) || isHelper(identifier) }
    /// Archive Utility starts the file viewer once more as it quits, naming nothing. When Helm isn't running yet, that
    /// arrives as a launch with no request and no sender, so it's told apart by Archive Utility still running.
    public static func isArchiveUtilityLaunch(running: [String]) -> Bool {
        running.contains { $0.lowercased() == "com.apple.archiveutility" }
    }
}

/// An archive or disk image Helm handed to one of Finder's helpers: Expand Archive, Open, a double-click, Open With
/// or a drop on the app. It's kept a few minutes, so what that helper shows afterwards comes back to Helm.
public struct HelperHandoff: Equatable, Sendable {
    /// The helper's bundle identifier, lowercased.
    public let helper: String
    public let item: URL
    public let date: Date
    /// The names in the item's folder when it was handed over, so what the helper adds there can be picked out. Nil when unknown.
    public let namesBefore: Set<String>?
    public var folder: URL { item.deletingLastPathComponent() }

    public init(helper: String, item: URL, date: Date, namesBefore: Set<String>? = nil) {
        self.helper = helper.lowercased()
        self.item = item
        self.date = date
        self.namesBefore = namesBefore
    }

    /// What the helper added to the folder, given the names there now, in name order. Empty when nothing is known.
    public func added(in names: Set<String>) -> [String] {
        guard let namesBefore else { return [] }
        return names.subtracting(namesBefore).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}

/// What a request to the file viewer asked for, as macOS delivers it.
public enum ViewerRequest: Equatable, Sendable {
    /// An open-documents event. NSWorkspace delivers Show in Finder this way, and so do `open -a` and drops on the icon.
    case open([URL])
    /// A make-objects-visible event: an explicit reveal.
    case reveal([URL])
    /// A reopen with nothing in it: a reveal of no items arrives this way, and so do a click on the Dock icon and a
    /// double-click on Helm in a Finder window while Helm is running.
    case reopen

    public var items: [URL] {
        switch self {
        case .open(let items), .reveal(let items): return items
        case .reopen: return []
        }
    }
}

/// Where a request goes.
public enum ViewerRoute: Equatable, Sendable {
    /// Helm shows it. A reveal selects each item in its folder, folders included; an open shows a folder's contents.
    /// `handoff` is the hand-off that explains the request, when Helm started the helper that sent it.
    case helm(reveal: Bool, handoff: HelperHandoff?)
    /// Finder shows it: these folders open in Finder. With none, Finder comes back to the front.
    case finder([URL])
}

/// The hand-offs Helm made in the last few minutes.
public struct HandoffLedger: Equatable, Sendable {
    /// Long enough for a big archive to expand, short enough that a later double-click in Finder isn't taken for Helm's.
    public static let lifetime: TimeInterval = 10 * 60
    public private(set) var handoffs: [HelperHandoff]

    public init(handoffs: [HelperHandoff] = []) { self.handoffs = handoffs }

    public mutating func record(_ handoff: HelperHandoff) {
        prune(now: handoff.date)
        handoffs.removeAll { $0.helper == handoff.helper && Self.same($0.item, handoff.item) }
        handoffs.append(handoff)
    }

    public mutating func prune(now: Date) { handoffs.removeAll { !Self.isLive($0, now: now) } }

    /// The latest live hand-off to `helper` that accounts for `items`: one of them is the handed item or sits in its
    /// folder, where Archive Utility puts what it expands. With no items, as when the helper brings the file viewer
    /// forward, the latest live hand-off to that helper.
    public func match(helper: String, items: [URL], now: Date) -> HelperHandoff? {
        let live = handoffs.filter { $0.helper == helper.lowercased() && Self.isLive($0, now: now) }
        guard !items.isEmpty else { return live.last }
        return live.last { handoff in
            items.contains { Self.same($0, handoff.item) || Self.same($0.deletingLastPathComponent(), handoff.folder) }
        }
    }

    /// The helper is done with everything Helm gave it: Archive Utility brings the file viewer forward as it quits.
    public mutating func forget(helper: String) { handoffs.removeAll { $0.helper == helper.lowercased() } }

    /// The helper quit: what Helm gave it up to `date` is done with, even if its last request never came. What
    /// Helm hands a new copy of it afterwards stays.
    public mutating func forget(helper: String, handedBefore date: Date) {
        handoffs.removeAll { $0.helper == helper.lowercased() && $0.date <= date }
    }

    private static func isLive(_ handoff: HelperHandoff, now: Date) -> Bool {
        let age = now.timeIntervalSince(handoff.date)
        return age >= -5 && age <= lifetime
    }

    static func same(_ a: URL, _ b: URL) -> Bool {
        PathSpelling.identity(PathSpelling.standardPath(a)) == PathSpelling.identity(PathSpelling.standardPath(b))
    }
}

/// Decides who shows a request: Helm, or Finder when the request started in Finder.
public enum ViewerRouter {
    public static func route(_ request: ViewerRequest, sender: String?, ledger: HandoffLedger, now: Date) -> ViewerRoute {
        if let sender, FinderFamily.isHelper(sender) {
            if let handoff = ledger.match(helper: sender, items: request.items, now: now) { return .helm(reveal: true, handoff: handoff) }
            return .finder(folders(of: request.items))
        }
        // Finder itself sends Helm only what you chose Helm for: Open With › Helm, a drop on Helm's icon, or a
        // double-click on Helm in a Finder window, which reaches a running Helm as a reopen. Those stay, as do
        // requests from any other app, or from one that can't be identified.
        if case .reveal = request { return .helm(reveal: true, handoff: nil) }
        return .helm(reveal: false, handoff: nil)
    }

    /// Each item's folder, once, in the order the items came.
    public static func folders(of items: [URL]) -> [URL] {
        var result: [URL] = []
        for item in items {
            let folder = item.deletingLastPathComponent()
            if !result.contains(where: { HandoffLedger.same($0, folder) }) { result.append(folder) }
        }
        return result
    }
}
