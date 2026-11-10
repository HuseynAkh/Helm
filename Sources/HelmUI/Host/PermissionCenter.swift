#if os(macOS)
import AppKit
import HelmCore
import Security

/// What Helm asks of macOS about privacy permissions. Behind a seam, so fixture runs and tests use a stand-in
/// and never open System Settings or look at the real home folder.
@MainActor public protocol PrivacyAccessProviding: AnyObject {
    /// Helm's app bundle, or nil when Helm runs outside one, from Terminal, where macOS applies Terminal's permissions.
    var appURL: URL? { get }
    /// An ad hoc signature changes with every build, and macOS forgets a permission given to the old one.
    var isAdHocSigned: Bool { get }
    func probeFullDiskAccess() async -> PrivacyAccessStatus
    /// Opens System Settings at the pane's row. False when nothing could be opened.
    @discardableResult func open(_ pane: PrivacyPane) -> Bool
    /// Shows the Trash in Finder, which can always read it.
    @discardableResult func openTrashInFinder() -> Bool
}

/// Tells whether Helm has Full Disk Access without asking macOS anything and without reading a single file:
/// it opens folders that only Full Disk Access guards, and closes them straight away.
public enum FullDiskAccessProbe {
    public enum Outcome: Sendable, Equatable { case opened, refused, missing, inconclusive }

    /// Only EPERM is macOS privacy refusing. EACCES is ordinary permissions, which says nothing about Full Disk Access.
    public static func probe(_ path: String) -> Outcome {
        guard let handle = opendir(path) else {
            let code = errno
            switch code {
            case EPERM: return .refused
            case ENOENT, ENOTDIR: return .missing
            default: return .inconclusive
            }
        }
        closedir(handle)
        return .opened
    }
    /// Any refusal means it's off. It's only reported on when a guarded folder actually opened.
    public static func decide(_ outcomes: [Outcome]) -> PrivacyAccessStatus {
        if outcomes.contains(.refused) { return .denied }
        if outcomes.contains(.opened) { return .granted }
        return .unknown
    }
}

/// The real Mac. Probes only `~/.Trash`, `~/Library/Safari` and `~/Library/Mail`: macOS never asks about those,
/// so looking can't bring up a question, and it never goes near the privacy database itself.
@MainActor public final class SystemPrivacyAccess: PrivacyAccessProviding {
    private let bundle: Bundle
    private let home: URL
    private var signature: Bool?
    public init(bundle: Bundle = .main, home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        self.bundle = bundle; self.home = home
    }

    public var appURL: URL? { bundle.bundleURL.pathExtension == "app" ? bundle.bundleURL : nil }

    public var isAdHocSigned: Bool {
        if let signature { return signature }
        let value = Self.readAdHocSignature()
        signature = value
        return value
    }

    static let probedFolders = [".Trash", "Library/Safari", "Library/Mail"]

    public func probeFullDiskAccess() async -> PrivacyAccessStatus {
        let paths = Self.probedFolders.map { home.appendingPathComponent($0, isDirectory: true).path }
        // Off the main thread, and never more than two seconds even if a disk hangs.
        return await withCheckedContinuation { continuation in
            let gate = ResumeOnce()
            DispatchQueue.global(qos: .utility).async {
                let status = FullDiskAccessProbe.decide(paths.map(FullDiskAccessProbe.probe))
                if gate.claim() { continuation.resume(returning: status) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                if gate.claim() { continuation.resume(returning: .unknown) }
            }
        }
    }

    /// The Privacy & Security extension's own address first (macOS 13 and later), then the older pane's.
    public static func settingsURLs(for pane: PrivacyPane) -> [URL] {
        ["com.apple.settings.PrivacySecurity.extension", "com.apple.preference.security"].compactMap {
            URL(string: "x-apple.systempreferences:\($0)?\(pane.anchor)")
        }
    }

    @discardableResult public func open(_ pane: PrivacyPane) -> Bool {
        for url in Self.settingsURLs(for: pane) where NSWorkspace.shared.open(url) { return true }
        return NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    /// Finder by name: when Helm is the default file viewer, an ordinary "show this" request comes straight back here.
    @discardableResult public func openTrashInFinder() -> Bool {
        let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder") ?? SystemFileViewerRole.finder
        let trash = home.appendingPathComponent(".Trash", isDirectory: true)
        NSWorkspace.shared.open([trash], withApplicationAt: finder, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    private static func readAdHocSignature() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return false }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let values = information as? [String: Any],
              let flags = (values[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value else { return false }
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0
    }
}

/// Resumes a continuation once, whichever of two racing callbacks gets there first.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// A fixture run's stand-in: a permission that's set by hand, and a record of what Helm asked for.
/// Nothing outside Helm changes.
@MainActor public final class MemoryPrivacyAccess: PrivacyAccessProviding {
    public var status: PrivacyAccessStatus
    public var appURL: URL?
    public var isAdHocSigned: Bool
    public private(set) var openedPanes: [PrivacyPane] = []
    public private(set) var trashOpenedInFinder = 0
    public init(status: PrivacyAccessStatus = .denied, appURL: URL? = URL(fileURLWithPath: "/Applications/Helm.app"),
                isAdHocSigned: Bool = true) {
        self.status = status; self.appURL = appURL; self.isAdHocSigned = isAdHocSigned
    }
    public func probeFullDiskAccess() async -> PrivacyAccessStatus { status }
    @discardableResult public func open(_ pane: PrivacyPane) -> Bool { openedPanes.append(pane); return true }
    @discardableResult public func openTrashInFinder() -> Bool { trashOpenedInFinder += 1; return true }
}

/// Full Disk Access as the app sees it, shared by every window, the welcome window and Settings.
/// It's checked at launch, whenever Helm comes back to the front, and every moment while the guide is on show.
@MainActor public final class PermissionCenter: ObservableObject {
    @Published public private(set) var fullDiskAccess: PrivacyAccessStatus = .unknown
    /// Sends each change of `fullDiskAccess`.
    public let changes = Broadcast<PrivacyAccessStatus>()
    public let provider: any PrivacyAccessProviding
    /// Shows the guide for a pane; the app sets this. A pane other than Full Disk Access usually just opens its row.
    public var presentGuide: ((PrivacyPane) -> Void)?
    private var watching: Task<Void, Never>?
    private var watchers = 0
    private var probes = 0

    public init(provider: any PrivacyAccessProviding) { self.provider = provider }

    public var appURL: URL? { provider.appURL }
    public var isAdHocSigned: Bool { provider.isAdHocSigned }

    /// Probes again and says so only if the answer changed. When probes overlap, the newest one decides.
    public func refresh() async {
        probes += 1
        let probe = probes
        let status = await provider.probeFullDiskAccess()
        guard probe == probes, status != fullDiskAccess else { return }
        fullDiskAccess = status
        changes.send(status)
    }

    /// Keeps probing while something on screen is waiting for access to arrive. Calls nest: each `true` needs a `false`.
    public func watch(_ on: Bool, every interval: TimeInterval = 1.5) {
        watchers = max(0, watchers + (on ? 1 : -1))
        if watchers == 0 { watching?.cancel(); watching = nil; return }
        guard watching == nil else { return }
        watching = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(nanoseconds: UInt64(max(0.2, interval) * 1_000_000_000))
            }
        }
    }
    public var isWatching: Bool { watching != nil }

    @discardableResult public func open(_ pane: PrivacyPane) -> Bool { provider.open(pane) }
    @discardableResult public func openTrashInFinder() -> Bool { provider.openTrashInFinder() }
    /// The Full Disk Access guide, or the pane's row if nothing is set to show a guide.
    public func showGuide(_ pane: PrivacyPane) {
        if let presentGuide { presentGuide(pane) } else { open(pane) }
    }
}
#endif
