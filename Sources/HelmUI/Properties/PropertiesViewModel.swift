import Foundation
import HelmCore
import HelmFileSystem

/// What Helm reads about one item for Properties, beyond what its row in the folder says. Nil means it couldn't be
/// read, never a guess.
public struct PropertiesSupplement: Sendable, Equatable {
    public var posixMode: UInt16?
    /// The owner when it isn't the person using this Mac, who is "You" instead: root, or another account by its
    /// number, since Helm reads no account's name. Then the group's name, and whether the owner is the person using
    /// this Mac.
    public var owner: String?
    public var group: String?
    public var ownerIsYou: Bool
    /// Finder's Locked.
    public var locked: Bool?
    /// Whether it has an access control list: rules beyond the owner, group and others.
    public var hasAccessList: Bool
    public var accessed: Date?
    /// The disk it's on, and that disk's free space and size.
    public var volumeName: String?
    public var volumeFree: Int64?
    public var volumeTotal: Int64?
    /// Where a link or an alias points.
    public var linkTarget: String?
    /// A picture's size in pixels, as "4032 × 3024".
    public var imageDimensions: String?
    /// Its type as a MIME type, as Nautilus shows it, else the type identifier.
    public var mimeType: String?
    /// The app that opens it when it's double-clicked.
    public var defaultApplication: String?
    /// Its mode and identity as a change to its permissions is checked against, and what stands in the way of one.
    public var permissionTarget: PermissionTarget?
    public init(posixMode: UInt16? = nil, owner: String? = nil, group: String? = nil, ownerIsYou: Bool = false,
                locked: Bool? = nil, hasAccessList: Bool = false, accessed: Date? = nil, volumeName: String? = nil,
                volumeFree: Int64? = nil, volumeTotal: Int64? = nil, linkTarget: String? = nil,
                imageDimensions: String? = nil, mimeType: String? = nil, defaultApplication: String? = nil,
                permissionTarget: PermissionTarget? = nil) {
        self.posixMode = posixMode; self.owner = owner; self.group = group; self.ownerIsYou = ownerIsYou
        self.locked = locked; self.hasAccessList = hasAccessList; self.accessed = accessed
        self.volumeName = volumeName; self.volumeFree = volumeFree; self.volumeTotal = volumeTotal
        self.linkTarget = linkTarget; self.imageDimensions = imageDimensions; self.mimeType = mimeType
        self.defaultApplication = defaultApplication; self.permissionTarget = permissionTarget
    }
}

/// One row of Properties: a label and its value, with a quieter line under the value when there's more to say.
public struct PropertiesRow: Equatable, Sendable {
    public let label: String
    public let value: String
    public let note: String?
    /// The value is still being worked out, such as a folder's contents while they're counted.
    public let isWorking: Bool
    /// A button beside the value shows the item in its folder.
    public let reveals: Bool
    /// A pop-up beside the value changes what this row's class of user can do, for an item the person owns.
    public let control: PermissionControl?
    public init(_ label: String, _ value: String, note: String? = nil, isWorking: Bool = false, reveals: Bool = false,
                control: PermissionControl? = nil) {
        self.label = label; self.value = value; self.note = note; self.isWorking = isWorking; self.reveals = reveals
        self.control = control
    }
}

/// Finder's privilege pop-up for one class of user: the person as owner, the group or everyone else.
public struct PermissionControl: Equatable, Sendable {
    public let subject: PermissionSubject
    /// What the pop-up shows chosen. Nil is Custom: the class's bits match none of Finder's three choices, and Custom
    /// is shown, but can't be chosen, until one of them is.
    public let choice: FinderAccess?
    public init(subject: PermissionSubject, choice: FinderAccess?) { self.subject = subject; self.choice = choice }
    /// What the pop-up reads.
    public var title: String { choice?.title ?? "Custom" }
}

/// Properties, as Nautilus shows them: for a folder what's inside it, counted, with its parent folder, its disk's free
/// space and its dates; for a file its size, type and the app that opens it; for several items how many of each and
/// their size together. Then who owns it and what each can do with it. It reads nothing itself: the window counts
/// and reads, and makes a new one of these as the answers come.
public struct PropertiesViewModel: Sendable {
    public let entries: [FileEntry]
    public let aggregate: PropertiesModel
    public let supplement: PropertiesSupplement
    /// What's inside the folders and packages among `entries`, so far, or nil before counting starts.
    public let contents: FolderContentsCount?
    public let counting: Bool
    /// Paths under it are written from ~.
    public let home: URL?
    /// What the last change to the permissions came to, when it didn't simply happen.
    public let permissionMessage: String?
    /// A change to the permissions is under way, so the controls wait for it.
    public let changingPermissions: Bool

    public init(entries: [FileEntry], supplement: PropertiesSupplement = PropertiesSupplement(),
                contents: FolderContentsCount? = nil, counting: Bool = false, home: URL? = nil,
                permissionMessage: String? = nil, changingPermissions: Bool = false) {
        var seen: Set<ItemID> = []
        let unique = entries.filter { seen.insert($0.id).inserted }
        self.entries = unique; aggregate = PropertiesModel(entries: unique)
        self.supplement = unique.count == 1 ? supplement : PropertiesSupplement()
        self.contents = contents; self.counting = counting; self.home = home
        self.permissionMessage = unique.count == 1 ? permissionMessage : nil
        self.changingPermissions = changingPermissions
    }

    // MARK: Header

    public var title: String { entries.count == 1 ? entries[0].name : "\(entries.count) Items" }
    public var kind: String {
        guard !entries.isEmpty else { return "Unknown" }
        return aggregate.commonKindDescription ?? (aggregate.hasMixedKinds ? "Multiple kinds" : "Unknown")
    }
    /// The window's title, as Nautilus words it.
    public var windowTitle: String { "\(title) Properties" }

    // MARK: Rows

    /// What it is and where: the rows above the permissions.
    public var generalRows: [PropertiesRow] {
        guard !entries.isEmpty else { return [] }
        if entries.count > 1 { return severalRows }
        let entry = entries[0]
        var rows: [PropertiesRow] = []
        if entry.isDirectoryLike {
            rows.append(contentsRow)
        } else {
            rows.append(PropertiesRow("Size", sizeText(of: entry), note: sizeNote(of: entry), isWorking: entry.kind == .package && counting))
            if let type = supplement.mimeType ?? entry.contentTypeIdentifier { rows.append(PropertiesRow("Type", type)) }
            if let dimensions = supplement.imageDimensions { rows.append(PropertiesRow("Dimensions", "\(dimensions) pixels")) }
            if let application = supplement.defaultApplication { rows.append(PropertiesRow("Opens With", application)) }
        }
        if let target = supplement.linkTarget { rows.append(PropertiesRow("Original", tilde(target))) }
        rows.append(PropertiesRow("Parent Folder", tilde(entry.url.deletingLastPathComponent().path), reveals: true))
        // The disk a folder is on, with its free space as the status bar words it, as Nautilus shows it for a folder.
        if entry.isDirectoryLike, let volume = supplement.volumeName {
            let bytes = LocalizedStatusByteFormatter()
            let free = supplement.volumeFree.map { free in
                bytes.string(from: free) + " free" + (supplement.volumeTotal.map { " of " + bytes.string(from: $0) } ?? "")
            }
            rows.append(PropertiesRow("Disk", volume, note: free))
        }
        for (label, date) in [("Created", entry.creationDate), ("Modified", entry.modificationDate)] as [(String, Date?)] + [("Accessed", supplement.accessed)] {
            if let text = Self.dateText(date) { rows.append(PropertiesRow(label, text)) }
        }
        return rows
    }

    /// Who owns it and what each can do with it, as Nautilus's Permissions page puts it. Only for one item. For an item
    /// the person can change, each class of user has Finder's pop-up, and a file's Runs as Program row gives way to
    /// the "Allow executing file as program" checkbox.
    public var permissionRows: [PropertiesRow] {
        guard entries.count == 1 else { return [] }
        let entry = entries[0]
        var rows: [PropertiesRow] = []
        let folder = isFolderForPermissions
        // Each with what it can do under it, as Nautilus pairs them.
        let mode = supplement.posixMode
        let can = { (shift: UInt16) in mode.map { Self.access(($0 >> shift) & 7, folder: folder) } }
        if showsPermissionControls, let mode {
            let control = { (subject: PermissionSubject) in
                PermissionControl(subject: subject, choice: FinderAccess(bits: mode >> UInt16(subject.rawValue), folder: folder))
            }
            rows.append(PropertiesRow("Owner", "You", note: can(6), control: control(.owner)))
            rows.append(PropertiesRow("Group", supplement.group ?? "", note: can(3), control: control(.group)))
            rows.append(PropertiesRow("Others", "", note: can(0), control: control(.everyone)))
        } else {
            if let owner = supplement.ownerIsYou ? "You" : supplement.owner { rows.append(PropertiesRow("Owner", owner, note: can(6))) }
            if let group = supplement.group { rows.append(PropertiesRow("Group", group, note: can(3))) }
            if let others = can(0) { rows.append(PropertiesRow("Others", others)) }
            if let mode, entry.kind == .regular { rows.append(PropertiesRow("Runs as Program", mode & 0o100 != 0 ? "Yes" : "No")) }
        }
        if let locked = supplement.locked { rows.append(PropertiesRow("Locked", locked ? "Yes" : "No")) }
        if supplement.hasAccessList { rows.append(PropertiesRow("Access List", "Has extra rules")) }
        return rows
    }

    /// Whether Finder's pop-ups are shown: for one item of the person's own, a file, folder, package or alias. Another
    /// account's or root's item is shown as it is, since only the owner may change its permissions without an
    /// administrator's password, and Helm never asks for one. So is a link, whose own permissions macOS doesn't use.
    public var showsPermissionControls: Bool {
        guard entries.count == 1, supplement.ownerIsYou, supplement.posixMode != nil,
              let target = supplement.permissionTarget else { return false }
        switch entries[0].kind {
        case .regular, .directory, .package, .alias: break
        case .symlinkToDirectory, .symlinkToFile, .danglingSymlink, .other: return false
        }
        return target.refusal != .notOwner && target.refusal != .link
    }
    /// Whether the controls can be used now: nothing stands in the way, such as Locked or a read-only disk, and no
    /// change is under way.
    public var permissionControlsEnabled: Bool {
        showsPermissionControls && supplement.permissionTarget?.refusal == nil && !changingPermissions
    }
    /// Whether Nautilus's "Allow executing file as program" is on, for a file of the person's own. Nil where it isn't
    /// shown: for a folder, an app or other package, an alias, and an item the person can't change.
    public var allowsExecuting: Bool? {
        guard showsPermissionControls, entries[0].kind == .regular, let mode = supplement.posixMode else { return nil }
        return PermissionEdit.allowsExecuting(mode)
    }
    /// Whether the checkbox would change anything. Turning it on lets each class that can read the file run it, so
    /// for a file nobody can read it's off and stays off.
    public var canToggleExecuting: Bool {
        guard let on = allowsExecuting, let mode = supplement.posixMode else { return false }
        return on || PermissionEdit.mode(mode, allowingExecution: true) != mode
    }
    /// The quieter line under the permissions: what the last change came to when it didn't simply happen, what stands
    /// in the way of a change, or, for an item Helm only shows, why it's shown and not changed.
    public var permissionsFooter: String? {
        guard entries.count == 1 else { return nil }
        if let permissionMessage { return permissionMessage }
        if showsPermissionControls { return supplement.permissionTarget?.refusal?.message }
        let shown = "Shown as macOS keeps them."
        switch entries[0].kind {
        case .symlinkToDirectory, .symlinkToFile, .danglingSymlink: return shown + " " + PermissionRefusal.link.message
        default: return supplement.ownerIsYou ? shown : shown + " " + PermissionRefusal.notOwner.message
        }
    }

    /// The mode choosing `access` in `subject`'s pop-up makes, from the mode on disk, or nil when there's no pop-up.
    public func mode(choosing access: FinderAccess, for subject: PermissionSubject) -> UInt16? {
        guard showsPermissionControls, let mode = supplement.permissionTarget?.mode else { return nil }
        return PermissionEdit.mode(mode, setting: access, for: subject, folder: isFolderForPermissions)
    }
    /// The mode the checkbox makes, turned on or off, or nil when there's no checkbox.
    public func mode(allowingExecution on: Bool) -> UInt16? {
        guard allowsExecuting != nil, let mode = supplement.permissionTarget?.mode else { return nil }
        return PermissionEdit.mode(mode, allowingExecution: on)
    }
    /// A folder needs execute to be opened, and so does an app or other package, which is a folder on disk.
    private var isFolderForPermissions: Bool { entries.first.map { $0.isDirectoryLike || $0.kind == .package } ?? false }

    /// What one class of user can do, after Nautilus's words: for a folder what they can do with the files in it, for
    /// a file whether they can read and change it. A mix Nautilus has no words for shows its letters.
    public static func access(_ bits: UInt16, folder: Bool) -> String {
        if folder {
            switch bits {
            case 7: return "Can create and delete files"
            case 5: return "Can access files"
            case 4: return "Can list files only"
            case 0: return "No access"
            default: return "Special (\(letters(bits)))"
            }
        }
        switch bits & 6 {
        case 6: return "Can read and write"
        case 4: return "Can only read"
        case 0: return "No access"
        default: return "Can only write"
        }
    }
    private static func letters(_ bits: UInt16) -> String {
        (bits & 4 != 0 ? "r" : "-") + (bits & 2 != 0 ? "w" : "-") + (bits & 1 != 0 ? "x" : "-")
    }

    // MARK: Contents

    /// A folder's Contents row: its items and their size, while they're counted and once they are.
    private var contentsRow: PropertiesRow {
        guard let contents else { return PropertiesRow("Contents", "Counting…", isWorking: true) }
        if contents.items == 0, !counting {
            if contents.notDownloaded > 0 {
                return PropertiesRow("Contents", "Not on this Mac", note: "It’s kept in the cloud, and Helm counts nothing that would need downloading.")
            }
            if contents.unreadable > 0 { return PropertiesRow("Contents", "Couldn’t be read") }
            return PropertiesRow("Contents", "Empty")
        }
        let text = Self.itemsText(contents.items) + ", totalling " + Self.bytesText(contents)
        return PropertiesRow("Contents", counting ? text + " so far" : text, note: Self.partialNote(contents), isWorking: counting)
    }
    private var severalRows: [PropertiesRow] {
        let folders = entries.filter(\.isDirectoryLike).count
        var picked: [String] = []
        if entries.count - folders > 0 { picked.append(Self.count(entries.count - folders, "file")) }
        if folders > 0 { picked.append(Self.count(folders, "folder")) }
        var rows = [PropertiesRow("Selected", picked.joined(separator: ", "))]
        let needsCount = entries.contains { $0.isDirectoryLike || $0.kind == .package }
        if let contents, needsCount {
            let inside = contents.items - (entries.count - folders)
            var note = inside > 0 ? "With \(Self.itemsText(inside)) inside the folders." : nil
            if let partial = Self.partialNote(contents) { note = [note, partial].compactMap { $0 }.joined(separator: " ") }
            rows.append(PropertiesRow("Size", Self.bytesText(contents) + (counting ? " so far" : ""), note: note, isWorking: counting))
        } else if needsCount {
            rows.append(PropertiesRow("Size", "Counting…", isWorking: true))
        } else {
            let known = entries.filter { $0.size >= 0 }.reduce(Int64(0)) { $0.addingReportingOverflow($1.size).overflow ? .max : $0 + $1.size }
            rows.append(PropertiesRow("Size", Self.sizeText(known)))
        }
        if aggregate.hasMixedLocations {
            rows.append(PropertiesRow("Parent Folder", "Several folders"))
        } else {
            rows.append(PropertiesRow("Parent Folder", tilde(entries[0].url.deletingLastPathComponent().path), reveals: true))
        }
        return rows
    }
    /// A file's size; a package's, such as an app, is everything inside it, counted.
    private func sizeText(of entry: FileEntry) -> String {
        if entry.kind == .package {
            guard let contents else { return "Counting…" }
            return counting ? Self.bytesText(contents) + " so far" : Self.bytesText(contents)
        }
        guard entry.size >= 0 else { return "Unknown" }
        return Self.sizeText(entry.size)
    }
    /// "3.4 MB (3,412,345 bytes)", or the bytes alone when that's all there is to say.
    static func sizeText(_ bytes: Int64) -> String {
        let short = ByteCountText.format(bytes), exact = ByteCountText.formatExact(bytes)
        return short == exact ? short : "\(short) (\(exact))"
    }
    private func sizeNote(of entry: FileEntry) -> String? {
        guard entry.kind == .package, let contents else { return nil }
        return Self.partialNote(contents)
    }
    private static func bytesText(_ contents: FolderContentsCount) -> String {
        contents.overflowed ? "more than Helm can add up" : ByteCountText.format(contents.bytes)
    }
    /// What wasn't counted, and why.
    static func partialNote(_ contents: FolderContentsCount) -> String? {
        var notes: [String] = []
        if contents.unreadable > 0 {
            notes.append("\(count(contents.unreadable, "folder").capitalizedFirst) inside couldn’t be read, so what’s in "
                         + (contents.unreadable == 1 ? "it isn’t" : "them isn’t") + " counted.")
        }
        if contents.notDownloaded > 0 {
            notes.append("\(count(contents.notDownloaded, "folder").capitalizedFirst) kept in the cloud "
                         + (contents.notDownloaded == 1 ? "isn’t" : "aren’t") + " on this Mac, so what’s in "
                         + (contents.notDownloaded == 1 ? "it isn’t" : "them isn’t") + " counted.")
        }
        return notes.isEmpty ? nil : notes.joined(separator: " ")
    }
    static func itemsText(_ items: Int) -> String { count(items, "item") }
    static func count(_ number: Int, _ noun: String) -> String {
        let formatter = NumberFormatter(); formatter.numberStyle = .decimal
        let digits = formatter.string(from: NSNumber(value: number)) ?? "\(number)"
        return "\(digits) \(noun)\(number == 1 ? "" : "s")"
    }

    // MARK: Words

    private func tilde(_ path: String) -> String {
        guard let home = home?.standardizedFileURL.path, !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
    static func dateText(_ date: Date?) -> String? {
        guard let date, date != .distantPast, date.timeIntervalSince1970 > 0 else { return nil }
        let formatter = DateFormatter(); formatter.dateStyle = .long; formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
