#if os(macOS)
import AppKit
import HelmCore

/// The archives and disk images Helm handed to Finder's helper apps in the last few minutes, shared by every window
/// and the app. What a helper shows afterwards comes back to Helm; anything else a helper sends goes to Finder.
@MainActor public final class HelperHandoffs {
    public private(set) var ledger = HandoffLedger()
    private let clock: any HelmClock

    public init(clock: any HelmClock = SystemHelmClock()) { self.clock = clock }

    public var now: Date { clock.now() }

    /// Notes each item handed to `application`, when that app is one of Finder's helpers. `namesBefore` gives the
    /// names in an item's folder at the time, when the window knows them.
    public func record(_ items: [URL], handedTo application: URL, namesBefore: (URL) -> Set<String>? = { _ in nil }) {
        guard let helper = Bundle(url: application)?.bundleIdentifier else { return }
        record(items, helper: helper, namesBefore: namesBefore)
    }

    /// The same, by the helper's bundle identifier. Anything that isn't one of Finder's helpers isn't noted.
    public func record(_ items: [URL], helper: String, namesBefore: (URL) -> Set<String>? = { _ in nil }) {
        guard FinderFamily.isHelper(helper) else { return }
        for item in items {
            ledger.record(HelperHandoff(helper: helper, item: item, date: clock.now(), namesBefore: namesBefore(item.deletingLastPathComponent())))
        }
    }

    /// Where a request goes, given who sent it.
    public func route(_ request: ViewerRequest, sender: String?) -> ViewerRoute {
        ledger.prune(now: clock.now())
        return ViewerRouter.route(request, sender: sender, ledger: ledger, now: clock.now())
    }

    /// The helper brought the file viewer forward as it quit, so it's done with everything Helm gave it.
    public func finished(helper: String) { ledger.forget(helper: helper) }

    /// The helper quit at `date`, so what Helm handed it before then is done with, whether or not its last request
    /// came. Otherwise a hand-off whose last request never came would take a double-click in Finder for Helm's.
    public func quit(helper: String, at date: Date) { ledger.forget(helper: helper, handedBefore: date) }
}
#endif
