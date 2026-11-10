import Foundation

/// The rows in System Settings › Privacy & Security that decide what macOS lets Helm read.
/// The raw value is the row's anchor, which a link into System Settings names.
public enum PrivacyPane: String, CaseIterable, Sendable {
    case fullDiskAccess = "Privacy_AllFiles"
    case filesAndFolders = "Privacy_FilesAndFolders"
    case media = "Privacy_Media"
    case photos = "Privacy_Photos"

    public var anchor: String { rawValue }
    /// The row's name as System Settings shows it.
    public var title: String {
        switch self {
        case .fullDiskAccess: return "Full Disk Access"
        case .filesAndFolders: return "Files & Folders"
        case .media: return "Media & Apple Music"
        case .photos: return "Photos"
        }
    }
}

/// What Helm could find out about a permission. Unknown means it couldn't tell, never that it's off.
public enum PrivacyAccessStatus: String, Sendable {
    case granted, denied, unknown
}

/// A folder macOS guards on top of ordinary permissions, and the System Settings row that opens it to Helm.
public struct PrivacyArea: Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case trash, protectedData, otherAppsData, desktop, documents, downloads, cloudFiles, mediaLibrary, photosLibrary
        /// A removable or network disk, which Files & Folders lets in as Removable Volumes or Network Volumes.
        case disk
    }
    public let kind: Kind
    public let root: URL
    public init(kind: Kind, root: URL) { self.kind = kind; self.root = root }

    public var pane: PrivacyPane {
        switch kind {
        case .trash, .protectedData, .otherAppsData: return .fullDiskAccess
        case .desktop, .documents, .downloads, .cloudFiles, .disk: return .filesAndFolders
        case .mediaLibrary: return .media
        case .photosLibrary: return .photos
        }
    }
    /// macOS asks before it first lets Helm in, and a read waits while that question is on screen.
    /// Nothing asks about the Trash or other apps' private data: only Full Disk Access opens them.
    public var asksFirst: Bool {
        switch kind {
        case .trash, .protectedData: return false
        default: return true
        }
    }
    /// macOS guards each app's container, and each cloud provider's files, on its own. Listing the area
    /// says nothing about one folder inside it.
    public var guardsEachChild: Bool { kind == .otherAppsData || kind == .cloudFiles }
    /// Full Disk Access opens this area too, so with it on, a refusal here isn't macOS privacy. Cloud providers
    /// and the music, TV and photo libraries keep switches of their own, which may still say no.
    public var isOpenedByFullDiskAccess: Bool {
        switch kind {
        case .cloudFiles, .mediaLibrary, .photosLibrary: return false
        default: return true
        }
    }
}

/// Which folders macOS guards, found by path. A refusal's error code can't tell macOS privacy apart from
/// ordinary permissions on its own, so the path decides which explanation and which Settings row apply.
public enum PrivacyAreas {
    /// Folders inside the home folder, deepest first wins when they nest.
    static let table: [(path: String, kind: PrivacyArea.Kind)] = [
        (".Trash", .trash),
        ("Library/Mail", .protectedData), ("Library/Messages", .protectedData), ("Library/Safari", .protectedData),
        ("Library/Cookies", .protectedData), ("Library/HomeKit", .protectedData), ("Library/Suggestions", .protectedData),
        ("Library/Containers", .otherAppsData), ("Library/Group Containers", .otherAppsData),
        ("Desktop", .desktop), ("Documents", .documents), ("Downloads", .downloads),
        ("Library/Mobile Documents", .cloudFiles), ("Library/CloudStorage", .cloudFiles),
        ("Music/Music", .mediaLibrary), ("Movies/TV", .mediaLibrary),
        ("Pictures/Photos Library.photoslibrary", .photosLibrary)
    ]

    public static func areas(home: URL) -> [PrivacyArea] {
        table.map { PrivacyArea(kind: $0.kind, root: home.appendingPathComponent($0.path, isDirectory: true)) }
    }

    /// The guarded folder `url` is in, or nil. A folder that only starts with the same letters isn't inside.
    public static func area(containing url: URL, home: URL) -> PrivacyArea? {
        let path = spelling(url)
        var best: (area: PrivacyArea, length: Int)?
        for area in areas(home: home) {
            let root = spelling(area.root)
            guard path == root || path.hasPrefix(root + "/") else { continue }
            if root.count > (best?.length ?? -1) { best = (area, root.count) }
        }
        return best?.area
    }

    /// The Trash is a place of its own; Recent is made of files from everywhere, so no one area applies.
    public static func area(for location: Location, home: URL) -> PrivacyArea? {
        switch location {
        case .trash: return areas(home: home).first { $0.kind == .trash }
        case .recent: return nil
        case .directory(let url): return area(containing: url, home: home)
        }
    }

    /// A disk's own folder in /Volumes, such as a USB stick or a server share. macOS asks before it lets Helm onto a
    /// removable or network disk, so that folder refusing Helm is macOS's answer: a disk's own folder is otherwise
    /// open to whoever mounted it. Folders further in, and the disk timing out, are explained as before, since
    /// ownership and a slow disk are just as likely there.
    public static func disk(for location: Location) -> PrivacyArea? {
        guard case .directory(let url) = location else { return nil }
        let path = PathSpelling.standardPath(url)
        let components = URL(fileURLWithPath: path).pathComponents
        guard components.count == 3, components[1].lowercased() == "volumes" else { return nil }
        return PrivacyArea(kind: .disk, root: URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Folders where a read can wait on a macOS question. Each gets its own I/O lane, so an unanswered
    /// question holds up only that folder rather than the whole disk.
    public static func askingRoots(home: URL) -> [URL] {
        areas(home: home).filter(\.asksFirst).map(\.root)
    }

    /// Compared the way the Mac's own disk compares names: case doesn't matter, nor does `/private` on temp paths.
    private static func spelling(_ url: URL) -> String {
        var path = PathSpelling.standardPath(url).lowercased()
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
