import Foundation
import HelmCore

/// A folder AI mode may work in: the folder on show in the tab, or one the person added.
public struct AgentScopeRoot: Hashable, Sendable, Identifiable {
    /// What a model calls the root, as in "r1". An alias is never used twice in a window's life, so an old plan
    /// can't point at a new folder.
    public let alias: String
    /// The canonical path.
    public let path: String
    /// The folder's name as the person sees it.
    public let label: String
    /// The name a model is given: "Home" for the home folder, the provider's name for a provider's folder, the
    /// kind's name for a mount point, and otherwise the folder's own name. So an account's name is never sent.
    public let modelName: String
    public let identity: FileObjectIdentity?
    public var storage: StorageFacts
    public let isTabFolder: Bool
    public var id: String { alias }
    public init(alias: String, path: String, label: String, modelName: String, identity: FileObjectIdentity?,
                storage: StorageFacts, isTabFolder: Bool) {
        self.alias = alias; self.path = path; self.label = label; self.modelName = modelName
        self.identity = identity; self.storage = storage; self.isTabFolder = isTabFolder
    }
}

/// Why a folder can't be one AI mode works in.
public enum AgentScopeRefusal: String, Error, Sendable { case notFound, notAFolder, system, hidden, insidePackage, full, badText, notResponding }

/// Text naming a folder, as the person gave it: typed, dropped, or the folder their tab shows. The initializer's
/// first label is `fromPerson`, and the privacy check lets only the panel's model and the window write it, so no
/// other code, and nothing a model said, can ask for a folder to be added.
public struct AgentRootInput: Sendable {
    public enum Origin: String, Sendable { case typed, dropped, tab }
    public let text: String
    public let origin: Origin
    public init(fromPerson text: String, origin: Origin) {
        self.text = text; self.origin = origin
    }
}

/// What the tab's folder is to AI mode.
public enum AgentTabFolder: Equatable, Sendable {
    /// The tab shows no folder: Recent, the Trash or search results.
    case none
    case root(AgentScopeRoot)
    /// The tab shows a folder the rules won't admit, so there is no tab root.
    case refused(AgentScopeRefusal)
}

/// What a folder the person named came to. Typing `/add`, dropping a folder and ending a message with a path all
/// get one of these back.
public enum AgentFolderRef: Equatable, Sendable {
    /// A new root.
    case added(AgentScopeRoot)
    /// A folder that was already a root.
    case root(AgentScopeRoot)
    /// A folder inside a root. It got a handle, and no new root was made.
    case inside(handle: String, name: String)
    case refused(AgentScopeRefusal)

    /// The alias or handle to put in a message in place of the path. Nil when the folder was refused.
    public var modelID: String? {
        switch self {
        case .added(let root), .root(let root): return root.alias
        case .inside(let handle, _): return handle
        case .refused: return nil
        }
    }
}

/// What a handle stands for. A model names existing items only by handles Helm issued, never by a path.
public struct AgentHandleRecord: Hashable, Sendable {
    /// "r1" for a root, "d7" for a folder, "f12" for anything else.
    public let handle: String
    public let rootAlias: String, path: String, name: String
    public let kind: FileEntryKind
    public let identity: FileObjectIdentity?
    public let size: Int64, modified: Date
    /// A file that isn't downloaded, or a folder whose names aren't loaded.
    public let isDataless: Bool
    public let isRoot: Bool
    /// A folder macOS asks about before letting an app in. It is listed by name and never entered.
    public let isProtectedLeaf: Bool
    /// The table's generation when the handle was made.
    public let generation: Int
    public init(handle: String, rootAlias: String, path: String, name: String, kind: FileEntryKind,
                identity: FileObjectIdentity?, size: Int64, modified: Date, isDataless: Bool, isRoot: Bool,
                isProtectedLeaf: Bool = false, generation: Int) {
        self.handle = handle; self.rootAlias = rootAlias; self.path = path; self.name = name; self.kind = kind
        self.identity = identity; self.size = size; self.modified = modified; self.isDataless = isDataless
        self.isRoot = isRoot; self.isProtectedLeaf = isProtectedLeaf; self.generation = generation
    }
}

/// Turns handles into items, and admits new ones. A plan is checked through this, so nothing a model wrote is ever
/// used as a path.
public protocol AgentHandleResolving: Sendable {
    func roots() async -> [AgentScopeRoot]
    /// Nil for a handle that was never issued and for one that was retired.
    func record(for handle: String) async -> AgentHandleRecord?
    func isRetired(_ handle: String) async -> Bool
    /// Whether an item is a root, told by its identity, so a second handle to a root is still a root.
    func isRoot(identity: FileObjectIdentity?, path: String) async -> Bool
    func children(of folder: AgentHandleRecord, limit: Int) async -> (records: [AgentHandleRecord], more: Int, state: AgentDiskListState)
    func admit(childNamed name: String, in folder: AgentHandleRecord) async -> Result<AgentHandleRecord, AgentToolCode>
    /// Nil when the record is still the same item and still inside its root.
    func recheck(_ record: AgentHandleRecord) async -> AgentToolCode?
    /// Nil when the root is gone or another folder has taken its place.
    func recheckRoot(alias: String) async -> AgentScopeRoot?
    /// The facts of this folder's own place, kept for the length of one request.
    func facts(forFolderAt path: String) async -> StorageFacts
}
