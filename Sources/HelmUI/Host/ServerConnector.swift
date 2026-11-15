#if os(macOS)
import AppKit
import HelmCore

/// Hands a server address to macOS, which asks for the password and mounts the share, as Finder's Connect to Server
/// does. Helm itself mounts nothing and adds nothing afterwards: a share macOS mounted is an ordinary folder.
@MainActor public protocol ServerConnecting: AnyObject {
    /// The address bar and Connect to Server: any address macOS can connect to.
    func open(_ url: URL) -> Bool
    /// What AI mode hands over when the person agrees to connect. A `ServerLocation` can only be smb, afp or nfs.
    func connect(_ location: ServerLocation) -> Bool
}

/// The real Mac's: macOS takes the address.
@MainActor public final class SystemServerConnector: ServerConnecting {
    public init() {}
    public func open(_ url: URL) -> Bool { NSWorkspace.shared.open(url) }
    public func connect(_ location: ServerLocation) -> Bool { NSWorkspace.shared.open(location.url) }
}

/// A fixture run's and a test's: it notes each address and opens nothing.
@MainActor public final class MemoryServerConnector: ServerConnecting {
    public init() {}
    /// Every address handed over, by either way, in order.
    public private(set) var opened: [URL] = []
    /// What each hand-over answers, as macOS would say whether it took the address.
    public var answer = true
    public func open(_ url: URL) -> Bool {
        opened.append(url)
        return answer
    }
    public func connect(_ location: ServerLocation) -> Bool {
        opened.append(location.url)
        return answer
    }
}
#endif
