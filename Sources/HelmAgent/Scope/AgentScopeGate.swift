import Foundation
import HelmCore

/// Decides which folders AI mode may work in. A folder is let in only from text the person gave, only in an
/// allowed place, and only once its real path is known.
///
/// The place test runs twice: on the text as typed, before the disk is asked anything, so a path under `/net` never
/// makes macOS mount a host; and again on the canonical path, so a link can't lead out of the allowed places.
/// Places are an allow list (`AgentItemFilter.area`): the home folder, the cloud folders in its Library, a disk in
/// the Volumes folder, and the Shared folder. Paths are compared part by part, never as text prefixes.
public struct AgentScopeGate: Sendable {
    /// What admitting a folder found: the root, made with the alias it was given, and the folder itself.
    struct Admission: Sendable {
        let root: AgentScopeRoot
        let item: AgentDiskItem
    }

    private let disk: any AgentDisk
    private let home: String
    private let supportFolder: String
    private let memo = Memo()

    /// `home` is the person's home folder and `supportFolder` Helm's own, which is never a root. The home is
    /// canonicalized once, the first time it is needed.
    public init(disk: any AgentDisk, home: String, supportFolder: String) {
        self.disk = disk
        self.home = home
        self.supportFolder = supportFolder
    }

    /// Admits a folder as a root named `alias`. `existing` is every root there is: a folder the person added is
    /// refused as `full` once seven added folders are there, unless it is one of them, inside one, or holds one.
    /// The tab's own folder always has its place.
    public func admitRoot(_ input: AgentRootInput, alias: String, existing: [AgentScopeRoot]) async -> Result<AgentScopeRoot, AgentScopeRefusal> {
        await admit(input, alias: alias, existing: existing).map(\.root)
    }

    /// Whether the folder at `path` is one macOS asks about before letting an app in (Desktop, Documents,
    /// Downloads, the music and TV libraries and the rest), under any root that holds it. Such a folder is listed by
    /// name and never entered, so a model can't raise a macOS privacy question. A root at or inside one of them was
    /// chosen by the person, so that one is open below it.
    public func isProtectedLeaf(path: String, under root: AgentScopeRoot) -> Bool {
        let homes = [home] + (memo.home.map { [$0] } ?? [])
        let parts = AgentPathParts.of(path).map { $0.lowercased() }, rootParts = AgentPathParts.of(root.path).map { $0.lowercased() }
        return homes.contains { home in
            PrivacyAreas.askingRoots(home: URL(fileURLWithPath: home, isDirectory: true)).contains { area in
                let areaParts = AgentPathParts.of(area.path).map { $0.lowercased() }
                guard !AgentPathParts.starts(rootParts, with: areaParts) else { return false }
                return parts.count == areaParts.count && AgentPathParts.starts(parts, with: areaParts)
            }
        }
    }

    // MARK: Admitting

    func admit(_ input: AgentRootInput, alias: String, existing: [AgentScopeRoot]) async -> Result<Admission, AgentScopeRefusal> {
        await admit(text: input.text, origin: input.origin, alias: alias, existing: existing)
    }

    /// Admits one of the places Whole Mac adds, by the same rules as a folder the person names: the place test on the
    /// path as given, before the disk is asked anything, and again on its real path; a real folder, not hidden, and
    /// answering. Helm finds these paths itself, from the home folder and the disks mounted; a model never names one.
    /// A disk's own folder is named for the model by its kind, never by the disk's name.
    func admitPlace(_ path: String) async -> Result<Admission, AgentScopeRefusal> {
        switch await admit(text: path, origin: nil, alias: "", existing: []) {
        case .failure(let refusal):
            return .failure(refusal)
        case .success(let found):
            let root = found.root
            let parts = AgentPathParts.of(root.path)
            let isDisk = parts.count == 3 && parts[1] == "Volumes"
            let model = isDisk && root.modelName == found.item.name ? Self.diskName(root.storage) : root.modelName
            return .success(Admission(root: AgentScopeRoot(alias: root.alias, path: root.path, label: root.label, modelName: model,
                                                           identity: root.identity, storage: root.storage, isTabFolder: false,
                                                           isWholeMac: true),
                                      item: found.item))
        }
    }

    /// `origin` is nil for a place Whole Mac adds, which never counts toward the added folders.
    private func admit(text: String, origin: AgentRootInput.Origin?, alias: String, existing: [AgentScopeRoot]) async -> Result<Admission, AgentScopeRefusal> {
        guard let typed = typedPath(text) else { return .failure(.badText) }
        let canonicalHome = await self.canonicalHome()
        // The place test on the text as typed. Nothing has been asked of the disk about this path yet.
        let homes = [home, canonicalHome]
        guard homes.contains(where: { AgentItemFilter.area(ofPath: typed, home: $0) != .refused }) else {
            return .failure(refusal(forRefused: typed, home: home))
        }
        guard let path = await disk.canonicalPath(typed) else { return .failure(.notFound) }
        if let refused = await placeRefusal(path) { return .failure(refused) }
        if AgentItemFilter.isInsidePackage(path: path) { return .failure(.insidePackage) }
        guard let item = await disk.item(at: path) else { return .failure(.notFound) }
        guard item.kind == .directory else { return .failure(.notAFolder) }
        if item.isHidden { return .failure(.hidden) }
        if let origin, origin != .tab, isFull(path, existing: existing) { return .failure(.full) }
        let storage = await disk.storage(of: path)
        guard storage.isResponding else { return .failure(.notResponding) }
        let names = self.names(of: path, item: item, storage: storage, home: canonicalHome)
        let root = AgentScopeRoot(alias: alias, path: path, label: names.label, modelName: names.model,
                                  identity: item.identity, storage: storage, isTabFolder: origin == .tab)
        return .success(Admission(root: root, item: item))
    }

    /// The home folder's canonical path, worked out once. A home the disk can't find is used as it was given.
    func canonicalHome() async -> String {
        if let known = memo.home { return known }
        let found = await disk.canonicalPath(home) ?? home
        memo.home = found
        return found
    }

    /// Whether an item at `path`, already known to be canonical, may be shown at all: in an allowed place, and not
    /// Helm's own support folder. The home's Library is refused here, which is how a listing of the home skips it.
    func allowsPlace(_ path: String) async -> Bool {
        await placeRefusal(path) == nil
    }

    // MARK: Rules

    /// The place test on a canonical path.
    private func placeRefusal(_ path: String) async -> AgentScopeRefusal? {
        let canonicalHome = await self.canonicalHome()
        if AgentItemFilter.area(ofPath: path, home: canonicalHome) == .refused {
            return refusal(forRefused: path, home: canonicalHome)
        }
        let support = await canonicalSupportFolder()
        if [supportFolder, support].contains(where: { AgentPathParts.isAt(path, orInside: $0) }) { return .system }
        return nil
    }

    private func canonicalSupportFolder() async -> String {
        if let known = memo.support { return known }
        let found = await disk.canonicalPath(supportFolder) ?? supportFolder
        memo.support = found
        return found
    }

    /// Hidden when a part below the place's own folder starts with a dot; otherwise a place outside the allow list.
    private func refusal(forRefused path: String, home: String) -> AgentScopeRefusal {
        let parts = AgentPathParts.of(path), homeParts = AgentPathParts.of(home)
        let below: ArraySlice<String>
        if homeParts.count > 1, AgentPathParts.starts(parts, with: homeParts) {
            below = parts.dropFirst(homeParts.count)
            if below.first?.lowercased() == "library" { return .system }
        } else if parts.count >= 3, parts[1] == "Volumes" {
            below = parts.dropFirst(3)
        } else if homeParts.count > 2, AgentPathParts.starts(parts, with: Array(homeParts.dropLast()) + ["Shared"]) {
            below = parts.dropFirst(homeParts.count)
        } else {
            return .system
        }
        return below.contains { $0.hasPrefix(".") } ? .hidden : .system
    }

    /// The person's text as an absolute path: a file address decoded, `~` made the home folder. Nil for text with
    /// a control character, text over 4,096 bytes, another host's file address, and a relative path or one with a
    /// `..` or `.` part.
    private func typedPath(_ text: String) -> String? {
        guard text.utf8.count <= Self.textBytes, !Self.hasControl(text) else { return nil }
        var path = text.trimmingCharacters(in: .whitespaces)
        if path.lowercased().hasPrefix("file://") {
            guard let decoded = TypedLocation.localPath(fromFileURL: path), !Self.hasControl(decoded) else { return nil }
            path = decoded
        }
        if path == "~" {
            path = home
        } else if path.hasPrefix("~/") {
            path = AgentPathParts.joined(AgentPathParts.of(home) + AgentPathParts.of(String(path.dropFirst(2))).dropFirst())
        }
        guard path.hasPrefix("/") else { return nil }
        let parts = AgentPathParts.of(path).dropFirst()
        guard !parts.contains(".."), !parts.contains(".") else { return nil }
        return AgentPathParts.joined(AgentPathParts.of(path))
    }

    private static func hasControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: return true
            default: return false
            }
        }
    }

    /// Seven added folders are there, and this one is none of them, inside none of them and holds none of them.
    /// The tab's folder and the places Whole Mac adds aren't added folders.
    private func isFull(_ path: String, existing: [AgentScopeRoot]) -> Bool {
        let added = existing.filter { !$0.isTabFolder && !$0.isWholeMac }
        guard added.count >= AgentLimits.roots - 1 else { return false }
        return !added.contains { AgentPathParts.isAt(path, orInside: $0.path) || AgentPathParts.isAt($0.path, orInside: path) }
    }

    /// The person's label and the model's name for a root. A model is told "Home" for the home folder, the
    /// provider's name for a provider's own folder and the kind's name for a disk or server's own folder, so an
    /// account, a host or the person's short name is never sent.
    private func names(of path: String, item: AgentDiskItem, storage: StorageFacts, home: String) -> (label: String, model: String) {
        if AgentPathParts.same(path, home) || AgentPathParts.same(path, self.home) { return (item.name, Self.homeName) }
        switch storage.kind {
        case .iCloud, .cloud:
            let parts = AgentPathParts.of(path)
            let isContainer = parts.count >= 2 && parts[parts.count - 2] == "Mobile Documents"
            if isContainer || storage.cloudRoot.map({ AgentPathParts.same(path, $0) }) == true { return (storage.name, storage.name) }
        case .network, .external:
            if storage.volumeRoot.map({ AgentPathParts.same(path, $0) }) == true { return (item.name, storage.name) }
        case .thisMac:
            break
        }
        return (item.name, item.name)
    }

    static let homeName = "Home"
    private static let textBytes = 4_096

    /// A disk's own folder as Whole Mac names it for a model: "Server" or "External disk" by its kind, and "Disk" for
    /// another disk inside this Mac, so a disk named after its owner never gives the name away.
    static func diskName(_ storage: StorageFacts) -> String {
        switch storage.kind {
        case .network, .external: return storage.name
        case .thisMac, .iCloud, .cloud: return "Disk"
        }
    }

    /// The two canonical paths, worked out once and kept. Reads and writes hold the lock.
    private final class Memo: @unchecked Sendable {
        private let lock = NSLock()
        private var homePath: String?
        private var supportPath: String?
        var home: String? {
            get { lock.lock(); defer { lock.unlock() }; return homePath }
            set { lock.lock(); defer { lock.unlock() }; homePath = newValue }
        }
        var support: String? {
            get { lock.lock(); defer { lock.unlock() }; return supportPath }
            set { lock.lock(); defer { lock.unlock() }; supportPath = newValue }
        }
    }
}
