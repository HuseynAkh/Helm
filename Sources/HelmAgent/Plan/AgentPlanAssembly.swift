import Foundation
import HelmCore

/// The facts of each folder a plan touches, each asked for once. While a plan is checked they come from the scope,
/// which keeps them for the request; right before Apply they come from the disk again, so a place that changed or
/// went quiet is seen.
final class AgentPlanFacts {
    enum Source { case scope(any AgentHandleResolving), disk(any AgentDisk) }

    private let source: Source
    private var known: [String: StorageFacts] = [:]

    init(_ source: Source) { self.source = source }

    func of(_ folder: String) async -> StorageFacts {
        if let facts = known[folder] { return facts }
        let facts: StorageFacts
        switch source {
        case .scope(let scope): facts = await scope.facts(forFolderAt: folder)
        case .disk(let disk): facts = await disk.storage(of: folder)
        }
        known[folder] = facts
        return facts
    }
}

/// Turns checked steps into Helm's own plan: place facts for every folder the steps touch, the place rules, the
/// bulk guard, groups, names already taken, notes and the title. Both checking a new plan and looking at one again
/// before Apply end here, so the two can't disagree about what a plan is.
struct AgentPlanAssembly {
    enum Failure: Error, Equatable {
        /// A folder's place didn't answer. Nothing is planned there.
        case notResponding(folder: String)
        /// The plan holds more changes than the strictest place it touches allows.
        case tooMany
    }

    let roots: [AgentScopeRoot]
    let disk: any AgentDisk
    let facts: AgentPlanFacts
    let limits: AgentLimits
    /// Whether a plan larger than its places allow is refused. A plan looked at again before Apply was already
    /// held to it.
    let holdsToPlaceLimits: Bool

    /// The plan for `steps`, in their order. `leftOut` and `carried` are what was left out before the steps got
    /// here, with the lines that name a place.
    func build(_ steps: [AgentPlanStep], leftOut: [AgentToolCode: Int],
               carried: [AgentPlanNotice]) async -> Result<AgentChangePlan, Failure> {
        let chart = AgentPlanChart(steps)
        // Every folder the steps touch, each read once, before any rule runs.
        for folder in chart.folders {
            if !(await facts.of(folder)).isResponding { return .failure(.notResponding(folder: folder)) }
        }
        if holdsToPlaceLimits {
            var strictest = limits.planSteps
            for folder in chart.folders { strictest = min(strictest, limits.adjusted(for: await facts.of(folder).kind).planSteps) }
            if steps.count > strictest { return .failure(.tooMany) }
        }

        var tally = leftOut
        var placeNotices = carried
        var rulings: [Int: AgentPlaceRules.Ruling] = [:]
        var leftKeys: [String: AgentToolCode] = [:]
        var walked: [String: Bool] = [:]
        for (index, step) in steps.enumerated() {
            guard let folders = chart.folders(of: index) else {
                if let key = chart.newKey(of: index) { leftKeys[key] = .not_allowed }
                rulings[index] = AgentPlaceRules.Ruling(leftOut: .not_allowed)
                continue
            }
            let source = await facts.of(folders.source)
            let destination = await folders.target.asyncMap { await facts.of($0) }
            var holdsDataless = false
            if let item = step.changedItem, item.isDataless {
                holdsDataless = true
            } else if let item = step.changedItem, item.kind == .directory || item.kind == .package, source.syncs,
                      AgentPlaceRules.needsBytes(step, source: source, destination: destination) {
                if let known = walked[item.path] {
                    holdsDataless = known
                } else {
                    holdsDataless = await holdsNotDownloaded(item.path, kind: source.kind)
                    walked[item.path] = holdsDataless
                }
            }
            // Notes name a place as its folder's chip does: the label of the root it is in.
            var targetName: String?
            if let target = folders.target, let destination { targetName = Self.placeName(of: target, roots: roots, facts: destination) }
            let names = (source: Self.placeName(of: folders.source, roots: roots, facts: source), target: targetName)
            let ruling = AgentPlaceRules.rule(for: step, source: source, destination: destination, holdsDataless: holdsDataless,
                                              names: names)
            rulings[index] = ruling
            if let code = ruling.leftOut, let key = chart.newKey(of: index) { leftKeys[key] = code }
        }
        // A step into a new folder that was left out is left out for the same reason.
        for index in steps.indices where rulings[index]?.leftOut == nil {
            if let code = chart.keysAbove(index).lazy.compactMap({ leftKeys[$0] }).first {
                rulings[index] = AgentPlaceRules.Ruling(leftOut: code)
            }
        }

        var kept: [Int] = []
        for index in steps.indices {
            guard let ruling = rulings[index] else { continue }
            if let code = ruling.leftOut {
                if code == .not_responding, let folders = chart.folders(of: index) {
                    return .failure(.notResponding(folder: folders.target ?? folders.source))
                }
                tally[code, default: 0] += 1
                for notice in ruling.notices where !placeNotices.contains(notice) { placeNotices.append(notice) }
            } else {
                kept.append(index)
            }
        }
        // Once changes were left out, a new folder that nothing goes into any more was never asked for on its own, so
        // it goes too: a plan never offers to make an empty folder in place of what it couldn't do.
        if tally.values.contains(where: { $0 > 0 }) {
            var used: Set<String> = []
            for index in kept where steps[index].landingTarget != nil { used.formUnion(chart.keysAbove(index)) }
            kept.removeAll { index in chart.newKey(of: index).map { !used.contains($0) } ?? false }
        }

        // Many changes, or any folder, in a place others are known to share.
        var changes: [AgentPlaceRules.PlaceChange] = []
        for index in kept {
            guard let folders = chart.folders(of: index) else { continue }
            let isFolder = steps[index].changedItem.map { $0.kind == .directory || $0.kind == .package } ?? false
            switch steps[index] {
            case .newFolder, .newFile:
                changes.append(.init(step: index, place: await facts.of(folders.source), isFolder: false))
            case .rename, .trash:
                changes.append(.init(step: index, place: await facts.of(folders.source), isFolder: isFolder))
            case .move:
                let source = await facts.of(folders.source)
                changes.append(.init(step: index, place: source, isFolder: isFolder))
                // A folder can be shared while the one the item comes from, in the same place, isn't; so the
                // destination counts whenever its facts differ from the source's, not only across places.
                if let target = folders.target {
                    let destination = await facts.of(target)
                    if destination != source {
                        changes.append(.init(step: index, place: destination, isFolder: isFolder))
                    }
                }
            case .copy:
                if let target = folders.target {
                    changes.append(.init(step: index, place: await facts.of(target), isFolder: isFolder))
                }
            }
        }
        for (index, place) in AgentPlaceRules.bulkGuarded(changes) where rulings[index]?.guardedBy == nil {
            rulings[index]?.guardedBy = .reachesOthers
            rulings[index]?.place = place
        }

        let finalSteps = kept.map { steps[$0] }
        let finalRulings = kept.map { rulings[$0] ?? AgentPlaceRules.Ruling() }
        let finalChart = AgentPlanChart(finalSteps)
        let groups = Self.groups(finalSteps, rulings: finalRulings, chart: finalChart, roots: roots)
        let keepsBoth = await takenNames(finalSteps)
        // Slot by slot: what was left out, what can't be undone, what syncs or is shared.
        var later: [AgentPlanNotice] = []
        for ruling in finalRulings {
            for notice in ruling.notices where notice.slot != 1 && !later.contains(notice) { later.append(notice) }
        }
        let notices = Self.leftOutNotices(tally) + placeNotices + later.filter { $0.slot == 2 } + later.filter { $0.slot == 3 }
        let title = Self.title(finalSteps, chart: finalChart, roots: roots)
        return .success(AgentChangePlan(title: title, steps: finalSteps, groups: groups, notices: notices,
                                        keepsBoth: keepsBoth, leftOut: tally.filter { $0.value > 0 }))
    }

    /// What a note calls the place a folder is in: the label of the root that holds it, as a chip and the line that
    /// says a place isn't responding name it, or else the kind of place.
    static func placeName(of folder: String, roots: [AgentScopeRoot], facts: StorageFacts) -> String {
        let parts = folder.split(separator: "/")
        let holder = roots.filter { root in
            let rootParts = root.path.split(separator: "/")
            return parts.count >= rootParts.count && Array(parts.prefix(rootParts.count)) == rootParts
        }.max { $0.path.count < $1.path.count }
        return holder?.label ?? facts.name
    }

    // MARK: Not downloaded

    /// Whether a folder in a place that syncs holds a file that isn't downloaded. Loaded folders are walked, up to
    /// `AgentLimits.datalessWalk` entries; a walk that can't finish, for any reason, counts as finding one, since a
    /// wrong yes leaves a step out and a wrong no would need a download.
    private func holdsNotDownloaded(_ folder: String, kind: StorageKind) async -> Bool {
        let seconds = limits.adjusted(for: kind).listSeconds
        var pending = [folder]
        var seen = 0
        while let next = pending.popLast() {
            let listing = await disk.list(next, limit: AgentLimits.datalessWalk - seen + 1, idleSeconds: seconds)
            guard listing.state == .ok, listing.unreadable == 0 else { return true }
            seen += listing.items.count + listing.more
            if seen > AgentLimits.datalessWalk { return true }
            for item in listing.items {
                if item.isDataless { return true }
                if item.kind == .directory || item.kind == .package { pending.append(item.path) }
            }
        }
        return false
    }

    // MARK: Names already taken

    /// Steps whose name is already taken where they go, by an item there or by an earlier step of the plan. Apply
    /// keeps both.
    private func takenNames(_ steps: [AgentPlanStep]) async -> Set<Int> {
        var present: [String: Set<String>] = [:]
        var arriving: [String: Set<String>] = [:]
        var taken: Set<Int> = []
        for (index, step) in steps.enumerated() {
            let place: String, folder: String?, name: String, own: String?
            switch step {
            case .move(let item, let target), .copy(let item, let target):
                switch target {
                case .existing(let destination): place = "e:" + destination.path; folder = destination.path
                case .new(let key): place = "n:" + key; folder = nil
                }
                name = item.name
                own = nil
            case .rename(let item, let newName):
                let parent = AgentPlanChart.parent(of: item.path)
                place = "e:" + parent; folder = parent
                name = newName.value
                own = AgentNewName.clashKey(item.name)
            case .newFile(let target, let newName, _):
                switch target {
                case .existing(let destination): place = "e:" + destination.path; folder = destination.path
                case .new(let key): place = "n:" + key; folder = nil
                }
                name = newName.value
                own = nil
            case .newFolder, .trash:
                continue
            }
            let key = AgentNewName.clashKey(name)
            if key == own { continue }
            var names = arriving[place] ?? []
            if let folder {
                if present[folder] == nil { present[folder] = await namesIn(folder) }
                names.formUnion(present[folder] ?? [])
            }
            if names.contains(key) { taken.insert(index) }
            arriving[place, default: []].insert(key)
        }
        return taken
    }

    private func namesIn(_ folder: String) async -> Set<String> {
        let listing = await disk.list(folder, limit: limits.entriesPerRequest, idleSeconds: limits.listSeconds)
        return Set(listing.items.map { AgentNewName.clashKey($0.name) })
    }

    // MARK: Groups

    private struct GroupKey: Hashable {
        enum Kind: Int { case newFolders, newFiles, renames, moves, copies, trash }
        var kind: Kind
        var destination: String?
        var guardedBy: AgentPlanGuard?
        var place: String?
    }

    /// One group a kind of change, destination, guard and place, in the card's order: new folders, new files,
    /// renames, moves, copies, the Trash. A new folder joins the group of the first step that goes into it or into a
    /// folder made inside it; one that nothing goes into is in a group of new folders.
    static func groups(_ steps: [AgentPlanStep], rulings: [AgentPlaceRules.Ruling], chart: AgentPlanChart,
                       roots: [AgentScopeRoot]) -> [AgentPlanGroup] {
        var keyOf: [Int: GroupKey] = [:]
        var firstInto: [String: Int] = [:]
        for (index, step) in steps.enumerated() {
            let ruling = rulings[index]
            switch step {
            case .newFolder: continue
            case .rename: keyOf[index] = GroupKey(kind: .renames, guardedBy: ruling.guardedBy, place: ruling.place)
            case .trash: keyOf[index] = GroupKey(kind: .trash, guardedBy: .trash)
            case .move(_, let target), .copy(_, let target), .newFile(let target, _, _):
                let kind: GroupKey.Kind
                switch step {
                case .move: kind = .moves
                case .copy: kind = .copies
                default: kind = .newFiles
                }
                keyOf[index] = GroupKey(kind: kind, destination: AgentPlanChart.destinationKey(target),
                                        guardedBy: ruling.guardedBy, place: ruling.place)
                for key in chart.keysAbove(index) where firstInto[key] == nil { firstInto[key] = index }
            }
        }
        for (index, step) in steps.enumerated() {
            guard case .newFolder(let key, _, _) = step else { continue }
            if let into = firstInto[key], let joined = keyOf[into] {
                keyOf[index] = joined
            } else {
                keyOf[index] = GroupKey(kind: .newFolders, guardedBy: rulings[index].guardedBy, place: rulings[index].place)
            }
        }
        var order: [GroupKey] = []
        var members: [GroupKey: [Int]] = [:]
        for index in steps.indices {
            guard let key = keyOf[index] else { continue }
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(index)
        }
        // A stable sort keeps first appearance within each kind.
        order = order.enumerated().sorted { ($0.element.kind.rawValue, $0.offset) < ($1.element.kind.rawValue, $1.offset) }.map(\.element)
        return order.enumerated().map { offset, key in
            let indexes = members[key] ?? []
            let kind: AgentPlanGroup.Kind
            switch key.kind {
            case .newFolders: kind = .newFolders
            case .renames: kind = .renames
            case .trash: kind = .trash
            case .moves, .copies, .newFiles:
                let target = indexes.lazy.compactMap { steps[$0].landingTarget }.first
                let label = target.map { chart.label(of: $0, roots: roots) } ?? ""
                let isNew: Bool
                if case .new? = target { isNew = true } else { isNew = false }
                switch key.kind {
                case .moves: kind = .moves(toLabel: label, isNew: isNew)
                case .copies: kind = .copies(toLabel: label, isNew: isNew)
                default: kind = .newFiles(toLabel: label, isNew: isNew)
                }
            }
            return AgentPlanGroup(id: offset + 1, kind: kind, steps: indexes, guardedBy: key.guardedBy, place: key.place)
        }
    }

    // MARK: Notes and title

    /// One line for each reason that counts changes; a place without a Trash or one that can only be viewed has its
    /// own line, which names the place.
    static func leftOutNotices(_ tally: [AgentToolCode: Int]) -> [AgentPlanNotice] {
        var notAllowed = 0, notDownloaded = 0, notLoaded = 0
        for (code, count) in tally where count > 0 {
            switch code {
            case .not_downloaded: notDownloaded += count
            case .not_loaded: notLoaded += count
            case .no_trash, .read_only: break
            default: notAllowed += count
            }
        }
        var notices: [AgentPlanNotice] = []
        if notAllowed > 0 { notices.append(.notAllowed(notAllowed)) }
        if notDownloaded > 0 { notices.append(.notDownloaded(notDownloaded)) }
        if notLoaded > 0 { notices.append(.foldersNotLoaded(notLoaded)) }
        return notices
    }

    /// The plan's name. A plan of one kind of change is named for it; moves into one folder are a move, and new
    /// files with the new folders they are made in are a creation; anything else organizes the root most of its
    /// items are in.
    static func title(_ steps: [AgentPlanStep], chart: AgentPlanChart, roots: [AgentScopeRoot]) -> AgentPlanTitle {
        var counts = AgentPlanCounts()
        var destinations: Set<String> = []
        var holdingFiles: Set<String> = []
        for (index, step) in steps.enumerated() {
            switch step {
            case .newFolder: counts.newFolders += 1
            case .newFile: counts.newFiles += 1; holdingFiles.formUnion(chart.keysAbove(index))
            case .move(_, let target): counts.moves += 1; destinations.insert(AgentPlanChart.destinationKey(target))
            case .copy: counts.copies += 1
            case .rename: counts.renames += 1
            case .trash: counts.trash += 1
            }
        }
        if !steps.isEmpty {
            if counts.trash == steps.count { return .trash(counts.trash) }
            if counts.renames == steps.count { return .rename(counts.renames) }
            if counts.copies > 0, counts.copies + counts.newFolders == steps.count { return .copy(counts.copies) }
            if counts.newFiles > 0, counts.newFiles + counts.newFolders == steps.count, steps.allSatisfy({ step in
                guard case .newFolder(let key, _, _) = step else { return true }
                return holdingFiles.contains(key)
            }) { return .create(counts.newFiles) }
            if counts.moves > 0, counts.moves + counts.newFolders == steps.count, destinations.count == 1 {
                let onTheWay = chart.keysAbove(destination: destinations.first ?? "")
                if steps.allSatisfy({ step in
                    guard case .newFolder(let key, _, _) = step else { return true }
                    return onTheWay.contains(key)
                }) { return .move(counts.moves) }
            }
        }
        var tally: [String: Int] = [:]
        for index in steps.indices { if let alias = chart.rootAlias(of: index) { tally[alias, default: 0] += 1 } }
        let best = roots.max { tally[$0.alias, default: 0] < tally[$1.alias, default: 0] }
        let root = tally.isEmpty ? (roots.first { $0.isTabFolder } ?? roots.first) : best
        return .organize(rootLabel: root?.label ?? "")
    }
}

/// How the steps of one plan hang together: which new folder each key is, where it is made, and the existing
/// folders each step's facts are read for.
struct AgentPlanChart {
    private let steps: [AgentPlanStep]
    private var parentOf: [String: AgentPlanTarget] = [:]
    private var nameOf: [String: String] = [:]

    init(_ steps: [AgentPlanStep]) {
        self.steps = steps
        for step in steps {
            if case .newFolder(let key, let parent, let name) = step { parentOf[key] = parent; nameOf[key] = name.value }
        }
    }

    /// The existing folder a target is in the place of: the folder itself, or the folder its new folders are made in.
    func anchor(of target: AgentPlanTarget) -> AgentPlanItem? {
        var current = target, hops = 0
        while case .new(let key) = current {
            guard hops <= AgentLimits.newFolderLevels, let parent = parentOf[key] else { return nil }
            current = parent
            hops += 1
        }
        if case .existing(let item) = current { return item }
        return nil
    }

    /// The folders whose facts a step is ruled by: the item's own folder (a file's parent; a folder itself), or the
    /// folder a new folder or file is made in; and the folder a move or a copy goes into. Nil when a new folder it
    /// needs isn't in the plan.
    func folders(of index: Int) -> (source: String, target: String?)? {
        switch steps[index] {
        case .newFolder(_, let parent, _), .newFile(let parent, _, _):
            guard let anchor = anchor(of: parent) else { return nil }
            return (anchor.path, anchor.path)
        case .move(let item, let target), .copy(let item, let target):
            guard let anchor = anchor(of: target) else { return nil }
            return (Self.ownFolder(of: item), anchor.path)
        case .rename(let item, _), .trash(let item):
            return (Self.ownFolder(of: item), nil)
        }
    }

    /// Every folder the steps touch, in the order they first appear.
    var folders: [String] {
        var seen: Set<String> = [], ordered: [String] = []
        for index in steps.indices {
            guard let pair = folders(of: index) else { continue }
            for folder in [pair.source, pair.target].compactMap({ $0 }) where seen.insert(folder).inserted {
                ordered.append(folder)
            }
        }
        return ordered
    }

    /// The key a step makes, for a new folder.
    func newKey(of index: Int) -> String? {
        if case .newFolder(let key, _, _) = steps[index] { return key }
        return nil
    }

    /// The new folders a step goes into or is made in, nearest first.
    func keysAbove(_ index: Int) -> [String] {
        switch steps[index] {
        case .newFolder(_, let parent, _), .newFile(let parent, _, _): return chain(from: parent)
        case .move(_, let target), .copy(_, let target): return chain(from: target)
        case .rename, .trash: return []
        }
    }

    /// The new folders on the way to a destination key, nearest first.
    func keysAbove(destination: String) -> Set<String> {
        guard destination.hasPrefix("n:") else { return [] }
        return Set(chain(from: .new(key: String(destination.dropFirst(2)))))
    }

    private func chain(from target: AgentPlanTarget) -> [String] {
        var keys: [String] = [], current = target
        while case .new(let key) = current, !keys.contains(key) {
            keys.append(key)
            guard let parent = parentOf[key] else { break }
            current = parent
        }
        return keys
    }

    /// The root a step's item, or the folder a new one is made in, belongs to.
    func rootAlias(of index: Int) -> String? {
        switch steps[index] {
        case .newFolder(_, let parent, _), .newFile(let parent, _, _): return anchor(of: parent)?.rootAlias
        case .move(let item, _), .copy(let item, _), .rename(let item, _), .trash(let item): return item.rootAlias
        }
    }

    /// The name a group shows for where its steps go: a root's label, a folder's name or a new folder's name.
    func label(of target: AgentPlanTarget, roots: [AgentScopeRoot]) -> String {
        switch target {
        case .existing(let item):
            return roots.first { $0.alias == item.handle || $0.path == item.path }?.label ?? item.name
        case .new(let key):
            return nameOf[key] ?? ""
        }
    }

    static func destinationKey(_ target: AgentPlanTarget) -> String {
        switch target {
        case .existing(let item): return "e:" + item.path
        case .new(let key): return "n:" + key
        }
    }

    static func ownFolder(of item: AgentPlanItem) -> String {
        item.kind == .directory || item.kind == .package ? item.path : parent(of: item.path)
    }

    static func parent(of path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count <= 1 ? "/" : "/" + parts.dropLast().joined(separator: "/")
    }
}

extension AgentPlanStep {
    /// The existing item a step changes. Nil for a new folder or a new file.
    var changedItem: AgentPlanItem? {
        switch self {
        case .newFolder, .newFile: return nil
        case .move(let item, _), .copy(let item, _), .rename(let item, _), .trash(let item): return item
        }
    }

    /// Where a move or a copy goes, or where a new file is made.
    var landingTarget: AgentPlanTarget? {
        switch self {
        case .move(_, let target), .copy(_, let target), .newFile(let target, _, _): return target
        case .newFolder, .rename, .trash: return nil
        }
    }
}

fileprivate extension Optional {
    /// The value mapped by an async function.
    func asyncMap<Mapped>(_ transform: (Wrapped) async -> Mapped) async -> Mapped? {
        guard let value = self else { return nil }
        return await transform(value)
    }
}
