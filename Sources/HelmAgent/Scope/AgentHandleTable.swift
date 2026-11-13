import Foundation
import HelmCore

/// The handles a model names items by: `r1` for a root, `d7` for a folder, `f12` for anything else.
///
/// Counters never go back, so a handle or a root's alias is never issued twice in a window's life, and an old plan
/// can't point at a new item. A retired handle is remembered, so it answers as stale rather than unknown.
public actor AgentHandleTable {
    private var records: [String: AgentHandleRecord] = [:]
    private var retired: Set<String> = []
    /// The live handle for an item, by its root and path, so listing a folder twice gives the same ids.
    private var byPlace: [String: String] = [:]
    private var serial = 0
    private var rootSerial = 0
    private var generation = 0

    public init() {}

    /// The handle for an item. A root's handle is its alias. An item listed before under the same root keeps its
    /// handle while it is the same object; one that was replaced gets a new handle and the old one is retired.
    public func mint(rootAlias: String, item: AgentDiskItem, isRoot: Bool, isProtectedLeaf: Bool) -> AgentHandleRecord {
        let place = Self.placeKey(rootAlias: rootAlias, path: item.path)
        let handle: String
        if isRoot {
            handle = rootAlias
            retired.remove(rootAlias)
        } else if let known = byPlace[place], let record = records[known], record.identity == item.identity, record.kind == item.kind {
            handle = known
        } else {
            if let known = byPlace[place] { retireHandle(known) }
            serial += 1
            handle = (item.kind == .directory ? "d" : "f") + String(serial)
        }
        let record = AgentHandleRecord(handle: handle, rootAlias: rootAlias, path: item.path, name: item.name, kind: item.kind,
                                       identity: item.identity, size: item.size, modified: item.modified,
                                       isDataless: item.isDataless, isRoot: isRoot, isProtectedLeaf: isProtectedLeaf,
                                       generation: generation)
        records[handle] = record
        byPlace[place] = handle
        return record
    }

    /// A new root alias. The counter never goes back, whatever is retired or cleared.
    public func nextRootAlias() -> String {
        rootSerial += 1
        return "r" + String(rootSerial)
    }

    /// Nil for a handle that was never issued and for one that was retired.
    public func record(for handle: String) -> AgentHandleRecord? { records[handle] }

    public func isRetired(_ handle: String) -> Bool { retired.contains(handle) }

    /// Retires every handle under a root, the root's own included.
    public func retire(rootAlias: String) {
        for (handle, record) in records where record.rootAlias == rootAlias { retireHandle(handle) }
    }

    /// Retires every handle, and starts a new generation.
    public func retireAll() {
        for handle in records.keys { retireHandle(handle) }
        generation += 1
    }

    /// How many handles are live.
    public var count: Int { records.count }

    /// Whether a thread has used up its handles. A root's handle is still made, so the folders stay usable.
    var isFull: Bool { records.count >= AgentLimits.handlesPerThread }

    private func retireHandle(_ handle: String) {
        guard let record = records.removeValue(forKey: handle) else { return }
        retired.insert(handle)
        let place = Self.placeKey(rootAlias: record.rootAlias, path: record.path)
        if byPlace[place] == handle { byPlace[place] = nil }
    }

    private static func placeKey(rootAlias: String, path: String) -> String { rootAlias + "\u{0}" + path }
}
