import Foundation

/// What kind of place a folder is in: on this Mac, in iCloud Drive, in another provider's cloud folder, on a server,
/// or on a disk that can be unplugged.
public enum StorageKind: String, Sendable, Codable, CaseIterable { case thisMac, iCloud, cloud, network, external }

/// An answer that may not be known. Unknown is never read as yes or as no.
public enum Tri: String, Sendable, Codable { case yes, no, unknown }

/// Raw facts about one folder, as a reader found them. Nil means the reader got no answer for that fact.
public struct StorageProbe: Equatable, Sendable {
    public var isLocal, isInternal, isRemovable, isEjectable, isReadOnly: Bool?
    public var isUbiquitous, isShared, hasTrash, hasSyncAttribute: Bool?
    /// The mount point, when the folder isn't on the startup disk.
    public var volumeRoot: String?
    /// The folder's disk or server didn't answer in time.
    public var timedOut: Bool
    public init(isLocal: Bool? = nil, isInternal: Bool? = nil, isRemovable: Bool? = nil, isEjectable: Bool? = nil,
                isReadOnly: Bool? = nil, isUbiquitous: Bool? = nil, isShared: Bool? = nil, hasTrash: Bool? = nil,
                hasSyncAttribute: Bool? = nil, volumeRoot: String? = nil, timedOut: Bool = false) {
        self.isLocal = isLocal; self.isInternal = isInternal; self.isRemovable = isRemovable
        self.isEjectable = isEjectable; self.isReadOnly = isReadOnly; self.isUbiquitous = isUbiquitous
        self.isShared = isShared; self.hasTrash = hasTrash; self.hasSyncAttribute = hasSyncAttribute
        self.volumeRoot = volumeRoot; self.timedOut = timedOut
    }
}

/// What Helm knows about the place one folder is in. The facts are the folder's own, never a whole root's: a home
/// folder can hold an iCloud Documents, a provider's mirror and plain folders side by side.
/// Hashable, so a listed item that carries its place can be kept in a set.
public struct StorageFacts: Hashable, Sendable {
    public var kind: StorageKind
    /// "This Mac", "iCloud Drive", a provider on the fixed list such as "Google Drive", "Cloud folder", "Server" or
    /// "External disk". Never an account, a host or a disk's own name.
    public var name: String
    /// Changes here are copied to the person's other devices: iCloud and cloud folders.
    public var syncs: Bool
    /// Whether other people see this folder. A server: yes. iCloud: yes or no. Other providers don't say: unknown.
    public var shared: Tri
    /// Whether the place has a Trash. A hint for a preview; what happens when something is moved there is the truth.
    public var trash: Tri
    public var isReadOnly: Bool
    /// False when the folder's disk or server didn't answer in time.
    public var isResponding: Bool
    /// The canonical path of the provider's folder, or of the folder it mirrors to. Nil outside cloud places.
    public var cloudRoot: String?
    /// The mount point of a server or an external disk.
    public var volumeRoot: String?
    public init(kind: StorageKind, name: String, syncs: Bool = false, shared: Tri = .no, trash: Tri = .yes,
                isReadOnly: Bool = false, isResponding: Bool = true, cloudRoot: String? = nil, volumeRoot: String? = nil) {
        self.kind = kind; self.name = name; self.syncs = syncs; self.shared = shared; self.trash = trash
        self.isReadOnly = isReadOnly; self.isResponding = isResponding
        self.cloudRoot = cloudRoot; self.volumeRoot = volumeRoot
    }

    /// An ordinary folder on the startup disk.
    public static let thisMac = StorageFacts(kind: .thisMac, name: StorageClassifier.thisMacName)

    /// The SF Symbol that stands for the kind.
    public var symbolName: String {
        switch kind {
        case .thisMac: return "folder"
        case .iCloud: return "icloud"
        case .cloud: return "cloud"
        case .network: return "network"
        case .external: return "externaldrive"
        }
    }
    /// The fixed word a model is given for the kind.
    public var modelWord: String {
        switch kind {
        case .thisMac: return "this_mac"
        case .iCloud: return "icloud"
        case .cloud: return "cloud"
        case .network: return "server"
        case .external: return "external"
        }
    }
    /// Two folders are in one place when their keys match. Cloud folders sit on the startup disk, so the provider's
    /// folder tells them apart from it and from each other; a server or a disk is told apart by its mount point.
    public var placeKey: String { cloudRoot ?? volumeRoot ?? "this-mac" }
    /// What is put here, or taken from here, is seen on other devices or by other people.
    public var isSeenElsewhere: Bool { syncs || shared == .yes || kind == .network }
    /// Helm knows other people see this place, which is more than knowing that it syncs.
    public var sharingIsKnown: Bool { kind == .network || shared == .yes }
}

/// Decides what kind of place a folder is in, from its canonical path and the raw facts a reader found.
/// Pure: the same inputs always give the same answer, and nothing is read here.
public enum StorageClassifier {
    /// The providers Helm names. A folder of any other provider is a "Cloud folder".
    public static let knownProviders = ["iCloud Drive", "Google Drive", "Dropbox", "OneDrive", "Box", "Nextcloud"]
    /// The starts of the attribute names sync apps put on the folders they keep in step. Only a name is ever
    /// compared. The names are as each app is believed to write them, and aren't yet confirmed on a Mac running one.
    public static let syncAttributePrefixes: [String] = ["com.dropbox.", "com.google.drivefs.", "com.microsoft.OneDrive",
                                                         "com.box.", "com.nextcloud."]

    static let thisMacName = "This Mac"
    static let iCloudName = "iCloud Drive"
    static let cloudFolderName = "Cloud folder"
    static let serverName = "Server"
    static let externalName = "External disk"

    /// The facts for the folder at `path`. `mirrors` maps the canonical path of each folder a provider mirrors to
    /// onto the name of that provider's folder in the home's CloudStorage folder.
    ///
    /// The first rule that fits decides the kind:
    /// 1. the reader got no answer in time: a server that isn't responding;
    /// 2. the disk isn't local: a server;
    /// 3. inside the home's `Library/Mobile Documents`: iCloud Drive;
    /// 4. inside a folder of the home's `Library/CloudStorage`: that provider's cloud folder;
    /// 5. at or inside a mirror target: that provider's cloud folder;
    /// 6. the folder itself is kept in a cloud: iCloud Drive in the home's Desktop or Documents, otherwise a cloud folder;
    /// 7. the folder carries a sync app's attribute: a cloud folder;
    /// 8. the disk isn't internal, or can be removed or ejected: an external disk;
    /// 9. otherwise this Mac.
    public static func classify(path: String, home: String, probe: StorageProbe, mirrors: [String: String] = [:]) -> StorageFacts {
        let volumeRoot = probe.volumeRoot ?? volumeMountPoint(of: path)
        if probe.timedOut {
            return StorageFacts(kind: .network, name: serverName, shared: .yes, trash: .unknown, isResponding: false,
                                volumeRoot: volumeRoot)
        }
        let readOnly = probe.isReadOnly ?? false
        if probe.isLocal == false {
            return StorageFacts(kind: .network, name: serverName, shared: .yes, trash: tri(probe.hasTrash, otherwise: .unknown),
                                isReadOnly: readOnly, volumeRoot: volumeRoot)
        }
        // A cloud folder in the home folder is on the startup disk, whose Trash is always there.
        let cloudTrash = tri(probe.hasTrash, otherwise: probe.volumeRoot == nil ? .yes : .unknown)
        func cloud(_ kind: StorageKind, _ name: String, root: String) -> StorageFacts {
            // iCloud answers whether a folder is shared. Other providers give no answer, which is not a no.
            let shared: Tri = probe.isShared == true ? .yes : (kind == .iCloud ? .no : .unknown)
            return StorageFacts(kind: kind, name: name, syncs: true, shared: shared, trash: cloudTrash, isReadOnly: readOnly,
                                cloudRoot: root, volumeRoot: probe.volumeRoot)
        }
        let parts = components(path), homeParts = components(home)
        if let root = iCloudRoot(parts, home: homeParts) { return cloud(.iCloud, iCloudName, root: root) }
        if let found = cloudStorageFolder(parts, home: homeParts) {
            return cloud(.cloud, providerName(ofFolder: found.folder), root: found.root)
        }
        if let target = mirrorTarget(of: parts, mirrors: mirrors), let folder = mirrors[target] {
            return cloud(.cloud, providerName(ofFolder: folder), root: target)
        }
        if probe.isUbiquitous == true {
            let inICloud = ["Desktop", "Documents"].contains { starts(parts, with: homeParts + [$0]) }
            // Desktop and Documents are part of iCloud Drive, so they share its root: a move between them and the
            // rest of iCloud Drive stays in one place.
            if inICloud { return cloud(.iCloud, iCloudName, root: joined(homeParts + ["Library", "Mobile Documents"])) }
            return cloud(.cloud, cloudFolderName, root: path)
        }
        // Where the folder's cloud ends isn't known, so the folder is a place of its own.
        if probe.hasSyncAttribute == true { return cloud(.cloud, cloudFolderName, root: path) }
        if probe.isInternal == false || probe.isRemovable == true || probe.isEjectable == true {
            return StorageFacts(kind: .external, name: externalName, trash: tri(probe.hasTrash, otherwise: .unknown),
                                isReadOnly: readOnly, volumeRoot: volumeRoot)
        }
        return StorageFacts(kind: .thisMac, name: thisMacName,
                            trash: tri(probe.hasTrash, otherwise: probe.volumeRoot == nil ? .yes : .unknown),
                            isReadOnly: readOnly, volumeRoot: probe.volumeRoot)
    }

    /// The provider's folder that holds `path`, told from the path alone: the home's `Library/Mobile Documents`, a
    /// folder of its `Library/CloudStorage`, or a mirror target. Nil when the path alone doesn't say.
    public static func cloudRoot(of path: String, home: String, mirrors: [String: String] = [:]) -> String? {
        let parts = components(path), homeParts = components(home)
        return iCloudRoot(parts, home: homeParts) ?? cloudStorageFolder(parts, home: homeParts)?.root
            ?? mirrorTarget(of: parts, mirrors: mirrors)
    }

    /// Whether the folder at `child` can be in a different place from the folder that holds it. That is so only for
    /// the home's Desktop and Documents, which iCloud can keep, and for a mirror target. Every other child is in its
    /// parent's place, so its facts needn't be read again.
    public static func mayDiffer(child: String, home: String, mirrors: [String: String]) -> Bool {
        let parts = components(child), homeParts = components(home)
        if same(parts, homeParts + ["Desktop"]) || same(parts, homeParts + ["Documents"]) { return true }
        return mirrors.keys.contains { same(parts, components($0)) }
    }

    /// The provider's name for a folder of CloudStorage, such as "GoogleDrive-me@example.com": one on the fixed list,
    /// or "Cloud folder". The account in the folder's name is never part of it.
    static func providerName(ofFolder folder: String) -> String {
        let provider = CloudDriveNaming.provider(ofFolder: folder)
        return knownProviders.first { $0.caseInsensitiveCompare(provider) == .orderedSame } ?? cloudFolderName
    }

    // MARK: Paths, by component

    /// A path's parts, with "/" first. Compared whole, so a folder whose name only starts like another isn't inside it.
    static func components(_ path: String) -> [String] {
        ["/"] + path.split(separator: "/").map(String.init)
    }
    static func joined(_ parts: [String]) -> String {
        parts.count <= 1 ? "/" : "/" + parts.dropFirst().joined(separator: "/")
    }
    /// Whether `parts` is `prefix` or inside it. Names match as the disk matches them, whatever form their accents
    /// are written in.
    static func starts(_ parts: [String], with prefix: [String]) -> Bool {
        parts.count >= prefix.count && zip(parts, prefix).allSatisfy { PathSpelling.identity($0) == PathSpelling.identity($1) }
    }

    static func same(_ parts: [String], _ other: [String]) -> Bool {
        parts.count == other.count && starts(parts, with: other)
    }

    private static func iCloudRoot(_ parts: [String], home: [String]) -> String? {
        let root = home + ["Library", "Mobile Documents"]
        return starts(parts, with: root) ? joined(root) : nil
    }
    /// The provider's folder and its name on disk, for a path at or inside one.
    private static func cloudStorageFolder(_ parts: [String], home: [String]) -> (root: String, folder: String)? {
        let storage = home + ["Library", "CloudStorage"]
        guard parts.count > storage.count, starts(parts, with: storage) else { return nil }
        return (joined(Array(parts.prefix(storage.count + 1))), parts[storage.count])
    }
    /// The mirror target `parts` is at or inside. The deepest one wins when targets nest.
    private static func mirrorTarget(of parts: [String], mirrors: [String: String]) -> String? {
        mirrors.keys.filter { starts(parts, with: components($0)) }.max { components($0).count < components($1).count }
    }
    /// A disk's own folder under the Volumes folder, read from the path when the reader gave no mount point.
    private static func volumeMountPoint(of path: String) -> String? {
        let parts = components(path)
        guard parts.count >= 3, parts[1] == "Volumes" else { return nil }
        return joined(Array(parts.prefix(3)))
    }
    private static func tri(_ answer: Bool?, otherwise: Tri) -> Tri {
        answer.map { $0 ? .yes : .no } ?? otherwise
    }
}
