#if os(macOS)
import Foundation
import HelmAgent
import HelmCore

/// One item a compiled command acts on, with the identity and kind it had when the plan was checked. The item is
/// read again right before its command runs, and left alone when it is no longer the same thing.
struct AgentCompiledSource: Equatable {
    let url: URL
    let identity: FileObjectIdentity?
    let kind: FileEntryKind
}

/// One rename inside a folder's batch.
struct AgentCompiledRename: Equatable {
    let source: AgentCompiledSource
    let name: ValidFileName
}

/// Where a command puts things: a folder that exists, or a folder an earlier command of the same plan makes.
enum AgentCompiledParent: Equatable { case url(URL), key(String) }

/// One file command of an approved plan.
enum AgentCompiledCommand: Equatable {
    case createFolder(key: String, parent: AgentCompiledParent, name: ValidFileName)
    /// A new file and the bytes it holds. Nil bytes: the document couldn't be made from the text, so nothing is.
    case createFile(parent: AgentCompiledParent, name: ValidFileName, contents: Data?)
    case batchRename([AgentCompiledRename]), move(sources: [AgentCompiledSource], to: AgentCompiledParent),
         copy(sources: [AgentCompiledSource], to: AgentCompiledParent), trash([AgentCompiledSource])
}

/// Turns the ticked groups of a checked plan into file commands, in the order they can run: the new folders a
/// ticked step needs, parents before the folders made inside them; then each new file with its bytes; one batch
/// of renames for each folder; one move for each destination; one copy for each destination; and the Trash last.
/// Pure: it reads nothing.
enum AgentPlanCompiler {
    static func commands(for plan: AgentChangePlan, ticked: Set<Int>) -> [AgentCompiledCommand] {
        let chosen = tickedSteps(of: plan, ticked: ticked)
        var commands = newFolders(of: plan, chosen: chosen, ticked: ticked)
        for index in plan.steps.indices where chosen.contains(index) {
            guard case .newFile(let target, let name, let text) = plan.steps[index] else { continue }
            let contents = AgentNewFileContents.data(name: name, text: text)
            commands.append(.createFile(parent: parent(target), name: name, contents: contents))
        }

        var renames = Buckets<String, AgentCompiledRename>()
        var moves = Buckets<AgentCompiledParent, AgentCompiledSource>()
        var copies = Buckets<AgentCompiledParent, AgentCompiledSource>()
        var trash: [AgentCompiledSource] = []
        for index in plan.steps.indices where chosen.contains(index) {
            switch plan.steps[index] {
            case .newFolder, .newFile:
                continue
            case .rename(let item, let name):
                renames.append(AgentCompiledRename(source: source(item), name: name), to: parentPath(of: item.path))
            case .move(let item, let target):
                moves.append(source(item), to: parent(target))
            case .copy(let item, let target):
                copies.append(source(item), to: parent(target))
            case .trash(let item):
                trash.append(source(item))
            }
        }
        commands += renames.buckets.map { AgentCompiledCommand.batchRename($0.values) }
        commands += moves.buckets.map { AgentCompiledCommand.move(sources: $0.values, to: $0.key) }
        commands += copies.buckets.map { AgentCompiledCommand.copy(sources: $0.values, to: $0.key) }
        if !trash.isEmpty { commands.append(.trash(trash)) }
        return commands
    }

    /// The indexes of every step in a ticked group.
    private static func tickedSteps(of plan: AgentChangePlan, ticked: Set<Int>) -> Set<Int> {
        var chosen: Set<Int> = []
        for group in plan.groups where ticked.contains(group.id) {
            chosen.formUnion(group.steps.filter { plan.steps.indices.contains($0) })
        }
        return chosen
    }

    /// The new folders a ticked step needs, each after the new folder it is made in. A folder is needed when it is in
    /// a ticked group of new folders, when a ticked move or copy goes into it or a ticked new file is made in it, or
    /// when a needed folder is made inside it. The rest are left out, as `AgentChangePlan.counts` leaves them out of
    /// the counts.
    private static func newFolders(of plan: AgentChangePlan, chosen: Set<Int>, ticked: Set<Int>) -> [AgentCompiledCommand] {
        var declared: [String: (parent: AgentPlanTarget, name: ValidFileName, index: Int)] = [:]
        for (index, step) in plan.steps.enumerated() {
            if case .newFolder(let key, let parent, let name) = step, declared[key] == nil { declared[key] = (parent, name, index) }
        }
        var needed: Set<String> = []
        for group in plan.groups where ticked.contains(group.id) && group.kind == .newFolders {
            for index in group.steps where plan.steps.indices.contains(index) {
                if case .newFolder(let key, _, _) = plan.steps[index] { needed.insert(key) }
            }
        }
        for index in chosen {
            switch plan.steps[index] {
            case .move(_, .new(let key)), .copy(_, .new(let key)), .newFile(.new(let key), _, _): needed.insert(key)
            default: break
            }
        }
        var pending = Array(needed)
        while let key = pending.popLast() {
            if case .new(let parent)? = declared[key]?.parent, needed.insert(parent).inserted { pending.append(parent) }
        }

        // In the plan's own order, but never before the folder it goes in.
        var made: Set<String> = []
        var commands: [AgentCompiledCommand] = []
        func make(_ key: String, visiting: Set<String>) {
            guard !made.contains(key), !visiting.contains(key), let folder = declared[key] else { return }
            if case .new(let parentKey) = folder.parent { make(parentKey, visiting: visiting.union([key])) }
            guard !made.contains(key) else { return }
            made.insert(key)
            commands.append(.createFolder(key: key, parent: parent(folder.parent), name: folder.name))
        }
        for key in needed.sorted(by: { (declared[$0]?.index ?? .max) < (declared[$1]?.index ?? .max) }) {
            make(key, visiting: [])
        }
        return commands
    }

    private static func source(_ item: AgentPlanItem) -> AgentCompiledSource {
        AgentCompiledSource(url: URL(fileURLWithPath: item.path, isDirectory: item.kind == .directory),
                            identity: item.identity, kind: item.kind)
    }

    private static func parent(_ target: AgentPlanTarget) -> AgentCompiledParent {
        switch target {
        case .existing(let folder): return .url(URL(fileURLWithPath: folder.path, isDirectory: true))
        case .new(let key): return .key(key)
        }
    }

    /// The folder an item is in, by its path's components, so "/a/b/" and "/a/b" are one folder.
    private static func parentPath(of path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        return "/" + parts.dropLast().joined(separator: "/")
    }

    /// Values gathered under keys, with the keys in the order each was first seen. Few keys, so they are compared
    /// one by one.
    private struct Buckets<Key: Equatable, Value> {
        private(set) var buckets: [(key: Key, values: [Value])] = []
        mutating func append(_ value: Value, to key: Key) {
            if let position = buckets.firstIndex(where: { $0.key == key }) {
                buckets[position].values.append(value)
            } else {
                buckets.append((key, [value]))
            }
        }
    }
}
#endif
