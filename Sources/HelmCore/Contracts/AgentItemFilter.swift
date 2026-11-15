import Foundation

/// Which places and names may be shown to a model. One filter, so a folder listed for a request and a row of an AI
/// search can never disagree about what leaves the Mac.
///
/// Places are an allow list, read from a path's components: the home folder, the cloud folders macOS keeps inside
/// its Library, a disk in the Volumes folder, and the Shared folder beside the home folders. Everything else is
/// refused, so a system folder can't be let in by being forgotten. Paths are compared part by part and never by a
/// prefix of text, and both `path` and `home` are canonical paths.
public enum AgentItemFilter {
    public enum Area: Equatable, Sendable { case home, cloud, volume, shared, refused }

    /// The area `path` is in.
    /// - `home`: the home folder or inside it, but not its Library, a Trash, or anything below a part that starts
    ///   with a dot. A dot part above the home doesn't count, so a home folder that itself sits under one works.
    /// - `cloud`: a provider's folder in the home's `Library/Mobile Documents` or `Library/CloudStorage`, or inside
    ///   one. Dot parts are allowed there, since providers keep folders of their own under such names.
    /// - `volume`: a disk's folder in the Volumes folder, or inside one, with no dot part.
    /// - `shared`: the Shared folder beside the home folders, or inside it, with no dot part.
    /// - `refused`: everything else.
    public static func area(ofPath path: String, home: String) -> Area {
        let parts = StorageClassifier.components(path), homeParts = StorageClassifier.components(home)
        guard !parts.contains(".."), !parts.dropFirst().contains(".") else { return .refused }
        if homeParts.count > 1, StorageClassifier.starts(parts, with: homeParts) {
            let below = Array(parts.dropFirst(homeParts.count))
            if let first = below.first, first.lowercased() == "library" {
                return isCloudFolder(below) ? .cloud : .refused
            }
            return below.contains(where: isDotName) ? .refused : .home
        }
        if homeParts.count > 2 {
            let shared = Array(homeParts.dropLast()) + ["Shared"]
            if StorageClassifier.starts(parts, with: shared) {
                return parts.dropFirst(shared.count).contains(where: isDotName) ? .refused : .shared
            }
        }
        if parts.count >= 3, parts[1] == "Volumes" {
            return parts.dropFirst(2).contains(where: isDotName) ? .refused : .volume
        }
        return .refused
    }

    /// Whether a name may be listed: not a dot name (which covers `._` sidecars and `.DS_Store`), not an app's lock
    /// file (`~$…`, `.~lock.…#`), and not marked hidden by macOS.
    public static func isListable(name: String, isHidden: Bool) -> Bool {
        !isHidden && !name.isEmpty && !isDotName(name) && !name.hasPrefix("~$")
    }

    /// Whether `path` is inside a package: a folder above it has a package's extension. A package is listed as one
    /// item and never looked into. The path's own last part isn't read, so a package itself is not inside one.
    public static func isInsidePackage(path: String) -> Bool {
        let above = Array(StorageClassifier.components(path).dropFirst().dropLast())
        return above.indices.contains { index in
            let name = above[index]
            // A provider's folder is named after an account, and an address can end like a package: "me@studio.app".
            if index >= 2, above[index - 1] == "CloudStorage", above[index - 2] == "Library" { return false }
            guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
            return packageExtensions.contains(name[name.index(after: dot)...].lowercased())
        }
    }

    /// Whether a name is a kind of file that holds keys or a wallet. Such a file's name is never a row of an AI
    /// search, where the words that find it may be a model's.
    public static func isSecretKind(name: String) -> Bool {
        let lower = name.lowercased()
        if secretNames.contains(lower) || secretNamePrefixes.contains(where: lower.hasPrefix) { return true }
        let parts = lower.split(separator: ".", omittingEmptySubsequences: false).dropFirst()
        return parts.contains { secretExtensions.contains(String($0)) }
    }

    /// Whether an item may be a row of an AI search: in an allowed area, listable, not inside a package and not a
    /// secret kind. Show Hidden Files makes no difference here.
    public static func allowsSearchRow(path: String, name: String, isHidden: Bool, home: String) -> Bool {
        area(ofPath: path, home: home) != .refused && isListable(name: name, isHidden: isHidden)
            && !isInsidePackage(path: path) && !isSecretKind(name: name)
    }

    /// A size to two significant figures, which is as exact as a model is told: 1,234,567 becomes 1,200,000.
    public static func roundedBytes(_ bytes: Int64) -> Int64 {
        guard bytes >= 100 else { return max(0, bytes) }
        var unit: Int64 = 1
        while bytes / unit >= 100 { unit *= 10 }
        // Half rounds up. The largest size there is rounds down, so the product always fits.
        return (bytes / unit + (bytes % unit >= unit / 2 ? 1 : 0)) * unit
    }

    /// Where an item is, in words that name no account, host or disk: "Home", "Documents", "Reports".
    /// Outside the home folder the first word is the place's own: a provider's name, "Shared", "External disk" or
    /// "Server". Used for the rows of a search sent to a model and for the tooltips of a folder's chip and of a cloud
    /// folder in the path bar. A refused path has no words.
    public static func placeWords(path: String, home: String, storage: StorageFacts) -> [String] {
        let parts = StorageClassifier.components(path), homeParts = StorageClassifier.components(home)
        switch area(ofPath: path, home: home) {
        case .refused: return []
        case .home: return ["Home"] + parts.dropFirst(homeParts.count)
        case .shared: return ["Shared"] + parts.dropFirst(homeParts.count)
        case .cloud:
            // Library, the cloud folder's parent and the provider's own folder, whose name can hold an account.
            let below = parts.dropFirst(homeParts.count + 3)
            if storage.kind == .iCloud || storage.kind == .cloud { return [storage.name] + below }
            let isICloud = parts[homeParts.count + 1] == "Mobile Documents"
            return [isICloud ? StorageClassifier.iCloudName : StorageClassifier.providerName(ofFolder: parts[homeParts.count + 2])] + below
        case .volume:
            // The disk's own name is left out. A provider's folder on a disk is named from the provider's folder down.
            if let root = storage.cloudRoot.map(StorageClassifier.components), StorageClassifier.starts(parts, with: root) {
                return [storage.name] + parts.dropFirst(root.count)
            }
            return [storage.name] + parts.dropFirst(3)
        }
    }

    // MARK: Rules

    private static func isDotName(_ name: String) -> Bool { name.hasPrefix(".") }

    /// `below` is the path's parts under the home folder, starting at Library. A cloud place is a folder of
    /// `Mobile Documents` or of `CloudStorage`, or anything inside one, except a Trash. The provider's own folder
    /// never starts with a dot; what macOS keeps beside the providers' folders under such a name isn't a place.
    private static func isCloudFolder(_ below: [String]) -> Bool {
        guard below.count >= 3, below[0] == "Library", below[1] == "Mobile Documents" || below[1] == "CloudStorage",
              !isDotName(below[2]) else { return false }
        return !below.dropFirst(3).contains { [".trash", ".trashes"].contains($0.lowercased()) }
    }

    /// Folders macOS shows as one item. A fixed list: nothing is asked of the system, so the answer is the same in
    /// a test and for a path that no longer exists.
    static let packageExtensions: Set<String> = [
        "app", "appex", "bundle", "framework", "plugin", "kext", "xpc", "prefpane", "saver", "qlgenerator", "mdimporter",
        "component", "vst", "vst3", "pkg", "mpkg", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary",
        "fcpbundle", "aplibrary", "band", "logicx", "rtfd", "pages", "numbers", "key", "xcodeproj", "xcworkspace",
        "playground", "xcarchive", "dsym", "docset", "sparsebundle", "download", "scptd", "workflow"
    ]

    /// Extensions of files that hold private keys, certificates with their keys, password stores and wallets.
    /// ".key" is left out on purpose: it is also a Keynote presentation, which is far more common.
    static let secretExtensions: Set<String> = [
        "pem", "p12", "pfx", "p8", "ppk", "jks", "keystore", "kdbx", "kdb", "keychain", "keychain-db", "agilekeychain",
        "opvault", "1pif", "wallet", "gpg", "pgp", "asc", "ovpn", "mobileprovision"
    ]
    static let secretNames: Set<String> = ["wallet.dat", "credentials", "credentials.json", "secrets.json"]
    static let secretNamePrefixes = ["id_rsa", "id_dsa", "id_ecdsa", "id_ed25519"]
}
