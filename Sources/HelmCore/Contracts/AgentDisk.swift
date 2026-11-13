import Foundation

/// What AI mode may learn about the disk: names and details, never what is inside a file.
/// Read-only by construction, since no method here changes anything. Every method runs with downloads off, so
/// nothing is fetched from a cloud to answer it, and answers within two seconds or as "no answer".
public protocol AgentDisk: Sendable {
    /// The path with every link in it resolved. Nil when any part of it is missing.
    func canonicalPath(_ path: String) async -> String?
    /// The item at `path` itself: a link is never followed. Nil when there is nothing there.
    func item(at path: String) async -> AgentDiskItem?
    /// The names in `folder` itself, sorted by name, `limit` at most. `idleSeconds` is how long the listing may go
    /// without progress, not how long it may take in all.
    func list(_ folder: String, limit: Int, idleSeconds: Double) async -> AgentDiskListing
    /// The facts of this folder's own place.
    func storage(of folder: String) async -> StorageFacts
}

/// One item as AI mode sees it.
public struct AgentDiskItem: Hashable, Sendable {
    public let path: String, name: String
    public let kind: FileEntryKind
    public let identity: FileObjectIdentity?
    public let size: Int64, modified: Date, created: Date
    public let typeIdentifier: String?
    public let isHidden: Bool
    /// A file that isn't downloaded, or a folder whose names aren't loaded.
    public let isDataless: Bool
    /// Set only on a child folder that is in a different place from the folder being listed.
    public let place: StorageFacts?
    public init(path: String, name: String, kind: FileEntryKind, identity: FileObjectIdentity?, size: Int64 = 0,
                modified: Date = .distantPast, created: Date = .distantPast, typeIdentifier: String? = nil,
                isHidden: Bool = false, isDataless: Bool = false, place: StorageFacts? = nil) {
        self.path = path; self.name = name; self.kind = kind; self.identity = identity; self.size = size
        self.modified = modified; self.created = created; self.typeIdentifier = typeIdentifier
        self.isHidden = isHidden; self.isDataless = isDataless; self.place = place
    }
}

/// How a listing ended: read; a cloud folder whose names aren't loaded; a place that stopped answering; a folder
/// macOS wouldn't let Helm read; or a folder that is gone.
public enum AgentDiskListState: String, Sendable { case ok, notLoaded, slow, denied, gone }

public struct AgentDiskListing: Sendable {
    public let items: [AgentDiskItem]
    /// How many entries there were past the limit.
    public let more: Int
    /// Children left out because their details couldn't be read.
    public let unreadable: Int
    public let state: AgentDiskListState
    public init(items: [AgentDiskItem], more: Int = 0, unreadable: Int = 0, state: AgentDiskListState = .ok) {
        self.items = items; self.more = more; self.unreadable = unreadable; self.state = state
    }
}
