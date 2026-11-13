import XCTest
import HelmCore
@testable import HelmAgent

/// A scope over a `MemoryAgentDisk` that hands out handles the way the real one does: roots by alias, everything
/// else as `d<n>` or `f<n>` minted from what the disk says. Tests mint handles for whatever they need, mark folders
/// macOS asks about, retire roots and count the place facts asked for.
actor AgentPlanTestScope: AgentHandleResolving {
    let disk: MemoryAgentDisk
    private var rootList: [AgentScopeRoot] = []
    private var records: [String: AgentHandleRecord] = [:]
    private var retired: Set<String> = []
    private var protectedPaths: Set<String> = []
    private var serial = 0
    private var rootSerial = 0
    private var cachedFacts: [String: StorageFacts] = [:]
    /// Every folder whose place facts were asked for, in order.
    private(set) var factsAsked: [String] = []

    init(disk: MemoryAgentDisk) { self.disk = disk }

    @discardableResult
    func addRoot(_ path: String, label: String? = nil, isTab: Bool = false) async -> AgentScopeRoot {
        rootSerial += 1
        let alias = "r\(rootSerial)"
        guard let item = await disk.item(at: path) else { fatalError("no folder at \(path)") }
        let storage = await disk.storage(of: path)
        let root = AgentScopeRoot(alias: alias, path: path, label: label ?? item.name, modelName: label ?? item.name,
                                  identity: item.identity, storage: storage, isTabFolder: isTab)
        rootList.append(root)
        records[alias] = AgentHandleRecord(handle: alias, rootAlias: alias, path: path, name: root.label, kind: item.kind,
                                           identity: item.identity, size: item.size, modified: item.modified,
                                           isDataless: item.isDataless, isRoot: true, generation: 0)
        return root
    }

    func protect(_ path: String) { protectedPaths.insert(path) }

    /// A handle for the item at `path`, under the root `alias`, or under the deepest root that holds it.
    func handle(_ path: String, under alias: String? = nil) async -> String {
        let root = alias.flatMap { wanted in rootList.first { $0.alias == wanted } }
            ?? rootList.filter { path == $0.path || path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
        guard let root else { fatalError("no root holds \(path)") }
        if root.path == path { return root.alias }
        if let known = records.values.first(where: { $0.path == path && $0.rootAlias == root.alias && !retired.contains($0.handle) }) {
            return known.handle
        }
        guard let item = await disk.item(at: path) else { fatalError("nothing at \(path)") }
        return mint(item, rootAlias: root.alias).handle
    }

    /// Drops a root, as when the tab moves on: its handles answer as retired from now on.
    func retireRoot(_ alias: String) {
        rootList.removeAll { $0.alias == alias }
        for record in records.values where record.rootAlias == alias { retired.insert(record.handle) }
    }

    private func mint(_ item: AgentDiskItem, rootAlias: String) -> AgentHandleRecord {
        serial += 1
        let handle = (item.kind == .directory ? "d" : "f") + String(serial)
        let record = AgentHandleRecord(handle: handle, rootAlias: rootAlias, path: item.path, name: item.name, kind: item.kind,
                                       identity: item.identity, size: item.size, modified: item.modified,
                                       isDataless: item.isDataless, isRoot: false,
                                       isProtectedLeaf: protectedPaths.contains(item.path), generation: 0)
        records[handle] = record
        return record
    }

    // MARK: AgentHandleResolving

    func roots() async -> [AgentScopeRoot] { rootList }

    func record(for handle: String) async -> AgentHandleRecord? {
        retired.contains(handle) ? nil : records[handle]
    }

    func isRetired(_ handle: String) async -> Bool { retired.contains(handle) }

    func isRoot(identity: FileObjectIdentity?, path: String) async -> Bool {
        rootList.contains { root in (identity != nil && root.identity == identity) || root.path == path }
    }

    func children(of folder: AgentHandleRecord, limit: Int) async -> (records: [AgentHandleRecord], more: Int, state: AgentDiskListState) {
        let listing = await disk.list(folder.path, limit: limit, idleSeconds: 3)
        let shown = listing.items.filter { AgentItemFilter.isListable(name: $0.name, isHidden: $0.isHidden) }
        return (shown.map { mint($0, rootAlias: folder.rootAlias) }, listing.more, listing.state)
    }

    func admit(childNamed name: String, in folder: AgentHandleRecord) async -> Result<AgentHandleRecord, AgentToolCode> {
        guard let item = await disk.item(at: folder.path + "/" + name) else { return .failure(.not_found) }
        return .success(mint(item, rootAlias: folder.rootAlias))
    }

    func recheck(_ record: AgentHandleRecord) async -> AgentToolCode? {
        if retired.contains(record.handle) { return .stale_id }
        guard await recheckRoot(alias: record.rootAlias) != nil else { return .stale_id }
        guard let now = await disk.item(at: record.path) else { return .not_found }
        return now.identity == record.identity && now.kind == record.kind ? nil : .stale_id
    }

    func recheckRoot(alias: String) async -> AgentScopeRoot? {
        guard let root = rootList.first(where: { $0.alias == alias }), let now = await disk.item(at: root.path),
              now.kind == .directory, now.identity == root.identity else { return nil }
        return root
    }

    func facts(forFolderAt path: String) async -> StorageFacts {
        factsAsked.append(path)
        if let known = cachedFacts[path] { return known }
        let facts = await disk.storage(of: path)
        cachedFacts[path] = facts
        return facts
    }
}

/// Shorthand for building proposals and reading verdicts.
enum AgentPlanTestKit {
    static func proposal(newFolders: [(key: String, parent: String, name: String)] = [],
                         moves: [(items: [String], allIn: String, to: String)] = [],
                         copies: [(items: [String], allIn: String, to: String)] = [],
                         renames: [(item: String, name: String)] = [], trash: [String] = []) -> AgentProposedChanges {
        AgentProposedChanges(
            newFolders: newFolders.map { .init(key: $0.key, parent: $0.parent, name: $0.name) },
            moves: moves.map { .init(items: $0.items, allIn: $0.allIn, to: $0.to) },
            copies: copies.map { .init(items: $0.items, allIn: $0.allIn, to: $0.to) },
            renames: renames.map { .init(item: $0.item, name: $0.name) },
            trash: trash)
    }

    static func plan(_ verdict: AgentPlanVerdict, file: StaticString = #filePath, line: UInt = #line) -> AgentChangePlan {
        guard case .plan(let plan) = verdict else {
            XCTFail("expected a plan, got \(verdict)", file: file, line: line)
            return AgentChangePlan(title: .move(0), steps: [], groups: [], notices: [], leftOut: [:])
        }
        return plan
    }

    /// Everything on the disk, read through `AgentDisk` alone: each item's path, kind, identity and marks. Two
    /// snapshots that are equal show nothing was changed.
    static func snapshot(_ disk: MemoryAgentDisk) async -> [String] {
        var lines: [String] = [], pending = ["/"]
        while let folder = pending.popLast() {
            let listing = await disk.list(folder, limit: 1_000_000, idleSeconds: 30)
            lines.append("\(folder) \(listing.state)")
            for item in listing.items {
                lines.append("\(item.path) \(item.kind) \(item.identity.map { $0.scope + "/" + $0.object } ?? "-") \(item.isDataless) \(item.size)")
                if item.kind == .directory || item.kind == .package { pending.append(item.path) }
            }
        }
        return lines.sorted()
    }

    /// The item a step changes, or the new folder's name.
    static func names(_ plan: AgentChangePlan) -> [String] {
        plan.steps.map { step in
            switch step {
            case .newFolder(let key, _, let name): return "new \(key) \(name.value)"
            case .move(let item, _): return "move \(item.name)"
            case .copy(let item, _): return "copy \(item.name)"
            case .rename(let item, let name): return "rename \(item.name) \(name.value)"
            case .trash(let item): return "trash \(item.name)"
            }
        }
    }

    static func group(_ plan: AgentChangePlan, holding index: Int) -> AgentPlanGroup? {
        plan.groups.first { $0.steps.contains(index) }
    }
}
