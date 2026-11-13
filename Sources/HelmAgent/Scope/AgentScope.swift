import Foundation
import HelmCore

/// One window's folders for AI mode and the handles that stand for what is in them.
///
/// The roots are the folder on show in the tab, which follows the tab under a new alias each time it changes, and
/// up to seven folders the person added. A handle is born only by listing a folder, or by the person naming a
/// folder inside a root, and every handle is checked against the disk again before it is used.
public actor AgentScope: AgentHandleResolving {
    /// What a listing found: each admitted child with the item it came from, and what was left out.
    struct ListedChildren: Sendable {
        var entries: [(record: AgentHandleRecord, item: AgentDiskItem)] = []
        /// Entries past the listing's limit.
        var more = 0
        /// Children whose details couldn't be read without a download.
        var unreadable = 0
        /// The thread has used up its handles, so some children got none.
        var outOfHandles = false
        var state: AgentDiskListState = .ok
    }

    private let disk: any AgentDisk
    private let gate: AgentScopeGate
    private let table = AgentHandleTable()
    private var tabRoot: AgentScopeRoot?
    private var added: [AgentScopeRoot] = []
    /// Folders macOS wouldn't let Helm list in this thread. They aren't asked about again.
    private var refusedFolders: Set<String> = []
    /// Facts of each folder's place, kept for one request.
    private var factsByFolder: [String: StorageFacts] = [:]
    /// Roots under which a file that isn't downloaded was listed.
    private var holdingCloudOnly: Set<String> = []
    private var listSecondsOverride: Double?

    public init(disk: any AgentDisk, home: String, supportFolder: String) {
        self.disk = disk
        self.gate = AgentScopeGate(disk: disk, home: home, supportFolder: supportFolder)
    }

    // MARK: Folders

    /// The tab's folder. A new folder becomes a root under a new alias and the old tab root's handles are retired.
    /// A folder the gate refuses leaves no tab root at all; it never stays on the previous folder.
    public func setTabFolder(_ input: AgentRootInput?) async -> AgentTabFolder {
        guard let input else {
            await dropTabRoot()
            return .none
        }
        switch await gate.admit(input, alias: "", existing: []) {
        case .failure(let refusal):
            await dropTabRoot()
            return .refused(refusal)
        case .success(let admission):
            if var current = tabRoot, AgentPathParts.same(current.path, admission.root.path), current.identity == admission.root.identity {
                current.storage = admission.root.storage
                tabRoot = current
                return .root(current)
            }
            await dropTabRoot()
            let root = await installRoot(admission, isTabFolder: true)
            tabRoot = root
            return .root(root)
        }
    }

    /// A folder the person named. One that is a root already answers with it; one inside a root gets a handle under
    /// that root; one that holds added roots takes their place. Behind a folder macOS guards, or on another disk
    /// than the root, a folder becomes a root of its own, since a root never enters those.
    public func folder(for input: AgentRootInput) async -> AgentFolderRef {
        let admission: AgentScopeGate.Admission
        switch await gate.admit(input, alias: "", existing: []) {
        case .failure(let refusal): return .refused(refusal)
        case .success(let found): admission = found
        }
        let path = admission.root.path
        let roots = allRoots
        if let known = roots.first(where: { AgentPathParts.same($0.path, path) || ($0.identity != nil && $0.identity == admission.root.identity) }) {
            return .root(known)
        }
        let holders = roots.filter { AgentPathParts.isStrictlyInside(path, $0.path) }
            .sorted { AgentPathParts.of($0.path).count > AgentPathParts.of($1.path).count }
        if let holder = holders.first, await isReachable(path, item: admission.item, from: holder) {
            if await table.isFull { return .refused(.full) }
            let record = await table.mint(rootAlias: holder.alias, item: admission.item, isRoot: false, isProtectedLeaf: false)
            return .inside(handle: record.handle, name: record.name)
        }
        let replaced = added.filter { AgentPathParts.isStrictlyInside($0.path, path) }
        guard added.count - replaced.count < AgentLimits.roots - 1 else { return .refused(.full) }
        for root in replaced { self.remove(alias: root.alias) }
        let root = await installRoot(admission, isTabFolder: false)
        added.append(root)
        return .added(root)
    }

    /// Removes a folder the person added, and retires its handles. They answer as retired at once; the table
    /// is told right after.
    public func remove(alias: String) {
        guard let index = added.firstIndex(where: { $0.alias == alias }) else { return }
        added.remove(at: index)
        retiredAliases.insert(alias)
        let table = self.table
        Task { await table.retire(rootAlias: alias) }
    }

    /// Drops the added folders and every handle. The tab's folder stays, under a new alias.
    public func clear() async {
        added.removeAll()
        await table.retireAll()
        forgetThread()
        if let current = tabRoot {
            let alias = await table.nextRootAlias()
            let root = AgentScopeRoot(alias: alias, path: current.path, label: current.label, modelName: current.modelName,
                                      identity: current.identity, storage: current.storage, isTabFolder: true)
            await mintRoot(root)
            tabRoot = root
        }
    }

    /// Retires every handle. The roots keep their aliases.
    public func startOver() async {
        await table.retireAll()
        forgetThread()
        for root in allRoots { await mintRoot(root) }
    }

    // MARK: AgentHandleResolving

    public func roots() -> [AgentScopeRoot] { allRoots }

    public func record(for handle: String) async -> AgentHandleRecord? {
        guard let record = await table.record(for: handle), !retiredAliases.contains(record.rootAlias) else { return nil }
        return record
    }

    public func isRetired(_ handle: String) async -> Bool {
        if await table.isRetired(handle) { return true }
        return await table.record(for: handle).map { retiredAliases.contains($0.rootAlias) } ?? false
    }

    public func isRoot(identity: FileObjectIdentity?, path: String) -> Bool {
        allRoots.contains { ($0.identity != nil && $0.identity == identity) || AgentPathParts.same($0.path, path) }
    }

    public func children(of folder: AgentHandleRecord, limit: Int) async -> (records: [AgentHandleRecord], more: Int, state: AgentDiskListState) {
        let facts = await facts(forFolderAt: folder.path)
        var seconds = AgentLimits.cloudModel.adjusted(for: facts.kind).listSeconds
        if let listSecondsOverride { seconds = listSecondsOverride }
        let listed = await listing(of: folder, limit: limit, idleSeconds: seconds, recheckingFirst: true)
        return (listed.entries.map(\.record), listed.more, listed.state)
    }

    public func admit(childNamed name: String, in folder: AgentHandleRecord) async -> Result<AgentHandleRecord, AgentToolCode> {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\u{0}") else { return .failure(.not_found) }
        if let code = enterable(folder) { return .failure(code) }
        if let code = await recheck(folder) { return .failure(code) }
        guard let root = root(alias: folder.rootAlias) else { return .failure(.stale_id) }
        guard let item = await disk.item(at: AgentPathParts.child(name, of: folder.path)) else { return .failure(.not_found) }
        switch await verdict(on: item, in: folder, root: root) {
        case .failure(let code): return .failure(code)
        case .success(let isLeaf):
            if await table.isFull { return .failure(.limit_reached) }
            return .success(await table.mint(rootAlias: root.alias, item: item, isRoot: false, isProtectedLeaf: isLeaf))
        }
    }

    public func recheck(_ record: AgentHandleRecord) async -> AgentToolCode? {
        guard let live = await self.record(for: record.handle) else {
            return await isRetired(record.handle) ? .stale_id : .unknown_id
        }
        guard AgentPathParts.same(live.path, record.path), live.identity == record.identity else { return .stale_id }
        guard let root = root(alias: record.rootAlias) else { return .stale_id }
        guard AgentPathParts.isAt(record.path, orInside: root.path) else { return .outside_scope }
        guard let rootItem = await disk.item(at: root.path), rootItem.identity == root.identity else { return .stale_id }
        if AgentPathParts.same(record.path, root.path) { return rootItem.identity == record.identity ? nil : .stale_id }
        guard let item = await disk.item(at: record.path) else { return .not_found }
        guard item.identity == record.identity, item.kind == record.kind else { return .stale_id }
        return nil
    }

    public func recheckRoot(alias: String) async -> AgentScopeRoot? {
        guard let root = root(alias: alias), let item = await disk.item(at: root.path), item.identity == root.identity,
              item.kind == .directory else { return nil }
        return root
    }

    public func facts(forFolderAt path: String) async -> StorageFacts {
        if let known = factsByFolder[path] { return known }
        let found = await disk.storage(of: path)
        factsByFolder[path] = found
        return found
    }

    // MARK: For the session and the tool runner

    /// Starts a request: the facts of each place are read again, and listings use `listSeconds` when it is set.
    func beginRequest(listSeconds: Double?) {
        factsByFolder.removeAll()
        listSecondsOverride = listSeconds
    }

    /// Drops every root whose folder is gone or was replaced by another, retires its handles and answers what was
    /// dropped.
    func dropChangedRoots() async -> [AgentScopeRoot] {
        var dropped: [AgentScopeRoot] = []
        for root in allRoots where await recheckRoot(alias: root.alias) == nil {
            dropped.append(root)
            retiredAliases.insert(root.alias)
            await table.retire(rootAlias: root.alias)
            if tabRoot?.alias == root.alias { tabRoot = nil }
            added.removeAll { $0.alias == root.alias }
        }
        return dropped
    }

    func isRefused(_ folder: String) -> Bool { refusedFolders.contains(folder) }

    func root(alias: String) -> AgentScopeRoot? { allRoots.first { $0.alias == alias } }

    /// Aliases of roots under which a file that isn't downloaded was listed in this thread.
    func rootsHoldingCloudOnly() -> Set<String> { holdingCloudOnly }

    /// The canonical home folder, for the check that it never leaves the app.
    func canonicalHome() async -> String { await gate.canonicalHome() }

    /// Lists a folder for a model: the children it may see, each with a handle. A folder macOS refused, a folder
    /// that is never entered and a cloud folder that isn't loaded answer without asking the disk.
    func listing(of folder: AgentHandleRecord, limit: Int, idleSeconds: Double, recheckingFirst: Bool) async -> ListedChildren {
        var listed = ListedChildren()
        if refusedFolders.contains(folder.path) || folder.isProtectedLeaf {
            listed.state = .denied
            return listed
        }
        guard folder.kind == .directory else {
            listed.state = .gone
            return listed
        }
        if folder.isDataless {
            listed.state = .notLoaded
            return listed
        }
        if recheckingFirst, await recheck(folder) != nil {
            listed.state = .gone
            return listed
        }
        guard let root = root(alias: folder.rootAlias) else {
            listed.state = .gone
            return listed
        }
        let found = await disk.list(folder.path, limit: limit, idleSeconds: idleSeconds)
        listed.state = found.state
        listed.more = found.more
        listed.unreadable = found.unreadable
        if found.state == .denied { refusedFolders.insert(folder.path) }
        guard found.state == .ok else { return listed }
        for item in found.items {
            guard AgentPathParts.same(item.path, AgentPathParts.child(item.name, of: folder.path)),
                  case .success(let isLeaf) = await verdict(on: item, in: folder, root: root) else { continue }
            if await table.isFull {
                listed.outOfHandles = true
                break
            }
            let record = await table.mint(rootAlias: root.alias, item: item, isRoot: false, isProtectedLeaf: isLeaf)
            if record.isDataless, record.kind != .directory { holdingCloudOnly.insert(root.alias) }
            listed.entries.append((record, item))
        }
        return listed
    }

    // MARK: Rules

    private var allRoots: [AgentScopeRoot] { (tabRoot.map { [$0] } ?? []) + added }

    /// Aliases of roots that were removed or dropped. Their handles answer as retired at once, even before the
    /// table has caught up.
    private var retiredAliases: Set<String> = []

    /// Whether a child may be shown, and whether it is a leaf: listed by name and never entered.
    /// Hidden and lock files, the home's Library and Helm's support folder are left out, as are sockets, pipes and
    /// devices. Links, packages, folders macOS asks about under a home root and folders on another disk are leaves.
    private func verdict(on item: AgentDiskItem, in folder: AgentHandleRecord, root: AgentScopeRoot) async -> Result<Bool, AgentToolCode> {
        guard AgentItemFilter.isListable(name: item.name, isHidden: item.isHidden) else { return .failure(.hidden) }
        guard await gate.allowsPlace(item.path) else { return .failure(.not_allowed) }
        if AgentItemFilter.isInsidePackage(path: item.path) { return .failure(.inside_package) }
        switch item.kind {
        case .other:
            return .failure(.not_allowed)
        case .symlinkToDirectory, .symlinkToFile, .danglingSymlink, .alias, .package, .regular:
            return .success(true)
        case .directory:
            let otherDisk = item.identity?.scope != nil && root.identity?.scope != nil && item.identity?.scope != root.identity?.scope
            return .success(otherDisk || gate.isProtectedLeaf(path: item.path, under: root))
        }
    }

    /// Why a folder can't be entered, if it can't.
    private func enterable(_ folder: AgentHandleRecord) -> AgentToolCode? {
        switch folder.kind {
        case .directory: break
        case .symlinkToDirectory, .symlinkToFile, .danglingSymlink, .alias: return .link
        case .package: return .inside_package
        case .regular, .other: return .not_allowed
        }
        if folder.isProtectedLeaf || refusedFolders.contains(folder.path) { return .not_allowed }
        return folder.isDataless ? .not_loaded : nil
    }

    /// Whether a folder inside `root` can be reached the way a listing would reach it: through no folder macOS
    /// guards, and on the root's own disk.
    private func isReachable(_ path: String, item: AgentDiskItem, from root: AgentScopeRoot) async -> Bool {
        guard item.identity?.scope == nil || root.identity?.scope == nil || item.identity?.scope == root.identity?.scope else { return false }
        let rootParts = AgentPathParts.of(root.path), parts = AgentPathParts.of(path)
        for count in (rootParts.count + 1)...parts.count {
            let step = AgentPathParts.joined(Array(parts.prefix(count)))
            if gate.isProtectedLeaf(path: step, under: root) || refusedFolders.contains(step) { return false }
            guard AgentItemFilter.isListable(name: parts[count - 1], isHidden: false) else { return false }
        }
        return true
    }

    private func installRoot(_ admission: AgentScopeGate.Admission, isTabFolder: Bool) async -> AgentScopeRoot {
        let found = admission.root
        let alias = await table.nextRootAlias()
        let root = AgentScopeRoot(alias: alias, path: found.path, label: found.label, modelName: found.modelName,
                                  identity: found.identity, storage: found.storage, isTabFolder: isTabFolder)
        await mintRoot(root)
        return root
    }

    private func mintRoot(_ root: AgentScopeRoot) async {
        let item = AgentDiskItem(path: root.path, name: root.label, kind: .directory, identity: root.identity)
        _ = await table.mint(rootAlias: root.alias, item: item, isRoot: true, isProtectedLeaf: false)
    }

    private func dropTabRoot() async {
        guard let current = tabRoot else { return }
        tabRoot = nil
        retiredAliases.insert(current.alias)
        await table.retire(rootAlias: current.alias)
    }

    private func forgetThread() {
        refusedFolders.removeAll()
        holdingCloudOnly.removeAll()
        factsByFolder.removeAll()
    }
}
