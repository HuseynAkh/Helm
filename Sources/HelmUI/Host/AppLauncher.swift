#if os(macOS)
import AppKit
import UniformTypeIdentifiers

/// What Helm asks of macOS about apps: which ones can open an item, handing items to one, and making one the default.
/// Behind a seam, so fixture runs and tests use a stand-in that opens nothing and changes no default.
@MainActor public protocol AppLaunching: AnyObject {
    /// Every app that can open the item, as Launch Services lists them.
    func applications(toOpen url: URL) -> [URL]
    /// The app that opens the item when it's double-clicked.
    func defaultApplication(toOpen url: URL) -> URL?
    /// Hands the items to the app, bringing it forward unless `activates` is false. `completion` gets what went wrong,
    /// if anything.
    func open(_ urls: [URL], withApplicationAt application: URL, activates: Bool, completion: @escaping @MainActor (Error?) -> Void)
    /// Makes the app the default for every file of this kind.
    func setDefaultApplication(at application: URL, toOpen type: UTType, completion: @escaping @MainActor (Error?) -> Void)
}

@MainActor public extension AppLaunching {
    /// Hands the items to the app and brings it forward, as a double-click does.
    func open(_ urls: [URL], withApplicationAt application: URL, completion: @escaping @MainActor (Error?) -> Void) {
        open(urls, withApplicationAt: application, activates: true, completion: completion)
    }
}

/// The real Mac.
@MainActor public final class SystemAppLauncher: AppLaunching {
    public init() {}
    public func applications(toOpen url: URL) -> [URL] { NSWorkspace.shared.urlsForApplications(toOpen: url) }
    public func defaultApplication(toOpen url: URL) -> URL? { NSWorkspace.shared.urlForApplication(toOpen: url) }
    public func open(_ urls: [URL], withApplicationAt application: URL, activates: Bool, completion: @escaping @MainActor (Error?) -> Void) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activates
        NSWorkspace.shared.open(urls, withApplicationAt: application, configuration: configuration) { _, error in
            Task { @MainActor in completion(error) }
        }
    }
    public func setDefaultApplication(at application: URL, toOpen type: UTType, completion: @escaping @MainActor (Error?) -> Void) {
        NSWorkspace.shared.setDefaultApplication(at: application, toOpen: type) { error in
            Task { @MainActor in completion(error) }
        }
    }
}

/// A fixture run's and a test's stand-in. It asks macOS which apps there are, which only reads, unless it's given a
/// catalog of its own. It records what Helm handed to which app and which defaults it asked for, and never opens an
/// app or changes a default. A default it was asked for is the one it reports from then on.
@MainActor public final class MemoryAppLauncher: AppLaunching {
    public struct Opening: Equatable, Sendable {
        public let urls: [URL]
        public let application: URL
        /// Whether the app was to come forward.
        public let activates: Bool
        public init(urls: [URL], application: URL, activates: Bool = true) {
            self.urls = urls; self.application = application; self.activates = activates
        }
    }
    public struct DefaultChange: Equatable, Sendable {
        public let application: URL
        public let type: String
        public init(application: URL, type: String) { self.application = application; self.type = type }
    }
    /// Which apps open an item, and its default, in place of asking macOS.
    public typealias Catalog = (URL) -> (applications: [URL], standard: URL?)
    public private(set) var openings: [Opening] = []
    public private(set) var defaultChanges: [DefaultChange] = []
    public var catalog: Catalog?
    /// What every open answers, as an app that's been removed would.
    public var failure: Error?

    public init(catalog: Catalog? = nil) { self.catalog = catalog }

    public func applications(toOpen url: URL) -> [URL] {
        catalog.map { $0(url).applications } ?? NSWorkspace.shared.urlsForApplications(toOpen: url)
    }
    public func defaultApplication(toOpen url: URL) -> URL? {
        if let kind = Self.kind(of: url), let changed = defaultChanges.last(where: { $0.type == kind }) { return changed.application }
        return catalog.map { $0(url).standard } ?? NSWorkspace.shared.urlForApplication(toOpen: url)
    }
    public func open(_ urls: [URL], withApplicationAt application: URL, activates: Bool, completion: @escaping @MainActor (Error?) -> Void) {
        openings.append(Opening(urls: urls, application: application, activates: activates))
        let failure = failure
        Task { @MainActor in completion(failure) }
    }
    public func setDefaultApplication(at application: URL, toOpen type: UTType, completion: @escaping @MainActor (Error?) -> Void) {
        defaultChanges.append(DefaultChange(application: application, type: type.identifier))
        Task { @MainActor in completion(nil) }
    }

    /// The kind of file at a URL: what the disk says, else what its extension says.
    private static func kind(of url: URL) -> String? {
        if let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType { return type.identifier }
        return url.pathExtension.isEmpty ? nil : UTType(filenameExtension: url.pathExtension)?.identifier
    }
}
#endif
