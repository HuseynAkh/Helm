import Foundation
import HelmCore

/// Turns what a model asked for in `propose_changes` into Helm's own plan, or refuses it. Nothing a model wrote is
/// used as a path: every existing item is a handle the scope issued, checked again on disk, and the only text taken
/// from the model is a new name, which passes `AgentNewName`. Steps that can't be done are left out and counted by
/// reason; the whole call is refused only when it is too large, malformed, or a place stops answering.
public struct AgentPlanValidator: AgentPlanValidating {
    public init() {}

    public func validate(_ proposal: AgentProposedChanges, scope: any AgentHandleResolving, disk: any AgentDisk,
                         limits: AgentLimits) async -> AgentPlanVerdict {
        if let code = AgentPlanIntake.refusal(of: proposal, limits: limits) { return .refused(code) }
        let roots = await scope.roots()
        let intake = AgentPlanIntake(scope: scope, disk: disk, limits: limits)
        let steps: [AgentPlanStep]
        do {
            steps = try await intake.steps(for: proposal)
        } catch let code as AgentToolCode {
            return .refused(code)
        } catch {
            return .refused(.bad_arguments)
        }
        let assembly = AgentPlanAssembly(roots: roots, disk: disk, facts: AgentPlanFacts(.scope(scope)), limits: limits,
                                         holdsToPlaceLimits: true)
        switch await assembly.build(steps, leftOut: intake.tally, carried: []) {
        case .success(let plan): return .plan(plan)
        case .failure(.tooMany): return .refused(.too_many)
        case .failure(.notResponding): return .refused(.not_responding)
        }
    }

    /// Looks at a plan again right before it runs. Every place it touches is asked again, and must answer. Then for
    /// each ticked step: its root is still the folder it was, the item is still the same object of the same kind,
    /// its folder still resolves to itself, and an existing destination is still the same folder. If anything
    /// changed, nothing may run, and the answer is a new plan without the steps that changed, its groups and guards
    /// worked out again from the places as they are now.
    public func recheck(_ plan: AgentChangePlan, ticked: Set<Int>, scope: any AgentHandleResolving,
                        disk: any AgentDisk) async -> AgentRecheck {
        let roots = await scope.roots()
        let facts = AgentPlanFacts(.disk(disk))
        let chart = AgentPlanChart(plan.steps)
        for folder in chart.folders {
            let place = await facts.of(folder)
            if !place.isResponding { return .notResponding(label: Self.label(of: folder, roots: roots, facts: place)) }
        }

        // Every root the plan uses, ticked or not: a step under a root that is gone or replaced can't stay.
        var aliases: [String] = []
        for step in plan.steps {
            for alias in Self.rootAliases(of: step) where !aliases.contains(alias) { aliases.append(alias) }
        }
        var lostRoots: Set<String> = []
        for alias in aliases {
            let before = roots.first { $0.alias == alias }
            let now = await scope.recheckRoot(alias: alias)
            if let now, before?.identity == nil || now.identity == before?.identity { continue }
            lostRoots.insert(alias)
            if let before, let volume = before.storage.volumeRoot, await disk.item(at: volume) == nil {
                return .disconnected(label: before.label)
            }
        }

        var failing = Set(plan.steps.indices.filter { !Set(Self.rootAliases(of: plan.steps[$0])).isDisjoint(with: lostRoots) })
        var fresh: [Int: AgentPlanStep] = [:]
        let tickedSteps = Set(plan.groups.filter { ticked.contains($0.id) }.flatMap(\.steps))
        for index in tickedSteps.sorted() where plan.steps.indices.contains(index) && !failing.contains(index) {
            let step = plan.steps[index]
            // The existing folder the step lands in, or the one its new folders are made in: a new folder's own
            // step may sit in a group that isn't ticked, and Apply still makes it for this one.
            if let destination = Self.destinationAnchor(of: step, chart: chart),
               await Self.stillThere(destination, folder: true, lostRoots: lostRoots, disk: disk) == nil {
                failing.insert(index)
                // The new folders on the way go too, and with them every other step made in them or sent into them.
                let above = Set(chart.keysAbove(index))
                for other in plan.steps.indices where chart.newKey(of: other).map(above.contains) == true {
                    failing.insert(other)
                }
                continue
            }
            guard let item = step.changedItem else { continue }
            guard let now = await Self.stillThere(item, folder: false, lostRoots: lostRoots, disk: disk) else {
                failing.insert(index)
                continue
            }
            if now.isDataless != item.isDataless {
                let renewed = AgentPlanItem(handle: item.handle, rootAlias: item.rootAlias, path: item.path, name: item.name,
                                            kind: item.kind, identity: item.identity, isDataless: now.isDataless, holds: item.holds)
                fresh[index] = step.with(item: renewed)
            }
        }
        // A new folder that changed takes every step made in it or sent into it along.
        var lostKeys: Set<String> = []
        for index in failing { if let key = chart.newKey(of: index) { lostKeys.insert(key) } }
        if !lostKeys.isEmpty {
            for index in plan.steps.indices where !chart.keysAbove(index).filter(lostKeys.contains).isEmpty {
                failing.insert(index)
            }
        }

        let steps = plan.steps.indices.filter { !failing.contains($0) }.map { fresh[$0] ?? plan.steps[$0] }
        let carried = plan.notices.filter {
            switch $0 {
            case .noTrash, .readOnly: return true
            default: return false
            }
        }
        let assembly = AgentPlanAssembly(roots: roots, disk: disk, facts: facts, limits: .cloudModel, holdsToPlaceLimits: false)
        switch await assembly.build(steps, leftOut: plan.leftOut, carried: carried) {
        case .failure(.notResponding(let folder)):
            return .notResponding(label: Self.label(of: folder, roots: roots, facts: await facts.of(folder)))
        case .failure(.tooMany):
            return .changed(AgentChangePlan(title: plan.title, steps: [], groups: [], notices: [], leftOut: plan.leftOut))
        case .success(let rebuilt):
            let same = failing.isEmpty && rebuilt.title == plan.title && rebuilt.steps == plan.steps
                && rebuilt.groups == plan.groups && rebuilt.notices == plan.notices && rebuilt.leftOut == plan.leftOut
            return same ? .ok : .changed(rebuilt)
        }
    }

    // MARK: Looking again

    /// The item as it is on disk now, when it is still the one the plan was made with: its root wasn't lost, the
    /// folder it is in still resolves to itself, and it is the same object of the same kind. Nil otherwise.
    private static func stillThere(_ item: AgentPlanItem, folder: Bool, lostRoots: Set<String>,
                                   disk: any AgentDisk) async -> AgentDiskItem? {
        guard !lostRoots.contains(item.rootAlias) else { return nil }
        let parent = AgentPlanChart.parent(of: item.path)
        guard await disk.canonicalPath(parent) == parent, let now = await disk.item(at: item.path),
              now.kind == item.kind, now.identity == item.identity else { return nil }
        if folder, await disk.canonicalPath(item.path) != item.path { return nil }
        return now
    }

    /// The existing folder a step puts something in, or makes a folder in.
    private static func existingFolder(of step: AgentPlanStep) -> AgentPlanTarget? {
        switch step {
        case .newFolder(_, let parent, _):
            if case .existing = parent { return parent }
            return nil
        case .move(_, let target), .copy(_, let target):
            if case .existing = target { return target }
            return nil
        case .rename, .trash:
            return nil
        }
    }

    /// The existing folder a step puts something in or makes a folder in, through any new folders on the way.
    private static func destinationAnchor(of step: AgentPlanStep, chart: AgentPlanChart) -> AgentPlanItem? {
        switch step {
        case .newFolder(_, let parent, _): return chart.anchor(of: parent)
        case .move(_, let target), .copy(_, let target): return chart.anchor(of: target)
        case .rename, .trash: return nil
        }
    }

    private static func rootAliases(of step: AgentPlanStep) -> [String] {
        var aliases: [String] = []
        if let item = step.changedItem { aliases.append(item.rootAlias) }
        if case .existing(let folder)? = existingFolder(of: step) { aliases.append(folder.rootAlias) }
        return aliases
    }

    /// What the person is told is quiet: the root the folder is in, or else the place.
    private static func label(of folder: String, roots: [AgentScopeRoot], facts: StorageFacts) -> String {
        let parts = folder.split(separator: "/")
        let holder = roots.filter { root in
            let rootParts = root.path.split(separator: "/")
            return parts.count >= rootParts.count && Array(parts.prefix(rootParts.count)) == rootParts
        }.max { $0.path.count < $1.path.count }
        return holder?.label ?? facts.name
    }
}

extension AgentPlanStep {
    /// The same step with its item replaced.
    func with(item: AgentPlanItem) -> AgentPlanStep {
        switch self {
        case .newFolder: return self
        case .move(_, let target): return .move(item, to: target)
        case .copy(_, let target): return .copy(item, to: target)
        case .rename(_, let name): return .rename(item, to: name)
        case .trash: return .trash(item)
        }
    }
}

/// Reads a proposal against the scope: resolves every handle and key, expands `all_in`, applies the name rules and
/// leaves out, with a count by reason, whatever can't be planned. Used once, for one proposal.
final class AgentPlanIntake {
    private let scope: any AgentHandleResolving
    private let disk: any AgentDisk
    private let limits: AgentLimits
    /// What was left out, by reason.
    private(set) var tally: [AgentToolCode: Int] = [:]
    private var resolved: [String: Result<AgentHandleRecord, AgentToolCode>] = [:]
    private var keys: [String: NewKey] = [:]
    private var lostKeys: [String: AgentToolCode] = [:]
    private var names: [String: [AgentDiskItem]] = [:]

    /// A key a new folder was declared under: a folder the plan makes, or one that already existed with its name.
    private struct NewKey {
        var target: AgentPlanTarget
        /// How many new folders deep it is, counting itself; 0 for an existing folder.
        var depth: Int
        /// The existing folder it is made in, and the key of the new folder above it, if any.
        var anchor: AgentHandleRecord
        var parentKey: String?
        var name: ValidFileName
    }

    /// A change asked of an existing item.
    private enum Ask {
        case move(AgentPlanTarget), copy(AgentPlanTarget), rename(ValidFileName), trash
    }

    init(scope: any AgentHandleResolving, disk: any AgentDisk, limits: AgentLimits) {
        self.scope = scope; self.disk = disk; self.limits = limits
    }

    /// Refuses a proposal as a whole before anything is looked up: more changes or new folders than one plan may
    /// hold, or a key that isn't `n` and a number, or is declared twice.
    static func refusal(of proposal: AgentProposedChanges, limits: AgentLimits) -> AgentToolCode? {
        let changes = proposal.newFolders.count + proposal.renames.count + proposal.trash.count
            + (proposal.moves + proposal.copies).reduce(0) { $0 + $1.items.count + ($1.allIn.isEmpty ? 0 : 1) }
        if changes > limits.planSteps || proposal.newFolders.count > limits.planNewFolders { return .too_many }
        var declared: Set<String> = []
        for folder in proposal.newFolders {
            guard isKey(folder.key), declared.insert(folder.key).inserted else { return .bad_arguments }
        }
        return nil
    }

    /// A key for a new folder: "n" and a number with no leading zero.
    static func isKey(_ text: String) -> Bool {
        guard text.count >= 2, text.count <= 7, text.first == "n" else { return false }
        let digits = text.dropFirst()
        return digits.first != "0" && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// The checked steps: new folders first, in the order they were declared, then moves, copies, renames and the
    /// Trash. Throws a code that ends the whole call.
    func steps(for proposal: AgentProposedChanges) async throws -> [AgentPlanStep] {
        var steps: [AgentPlanStep] = []
        for folder in proposal.newFolders {
            if let step = try await newFolder(folder) { steps.append(step) }
        }

        var asks: [(record: AgentHandleRecord, ask: Ask)] = []
        for (transfer, isCopy) in proposal.moves.map({ ($0, false) }) + proposal.copies.map({ ($0, true) }) {
            asks += try await transferAsks(transfer, isCopy: isCopy)
        }
        for change in proposal.renames {
            guard let record = try await source(change.item) else { continue }
            // A package is one item to the person, so it keeps its extension the way a file does.
            let checked = record.kind == .directory
                ? AgentNewName.validateFolderName(change.name, existing: record.name)
                : AgentNewName.validateFileRename(change.name, from: record.name)
            switch checked {
            case .failure(let code): count(code)
            case .success(let name):
                // A rename to the name it already has does nothing.
                if name.value != record.name { asks.append((record, .rename(name))) }
            }
        }
        for handle in proposal.trash {
            if let record = try await source(handle) { asks.append((record, .trash)) }
        }

        // An item may be in one step only. Told by identity, so two handles for one item are the same item.
        var seen: [String: Int] = [:]
        for entry in asks { seen[Self.identityKey(entry.record), default: 0] += 1 }
        var kept: [(record: AgentHandleRecord, ask: Ask)] = []
        for entry in asks {
            if seen[Self.identityKey(entry.record), default: 0] > 1 { count(.listed_twice) } else { kept.append(entry) }
        }
        let newFolders = steps.count
        guard newFolders + kept.count <= limits.planSteps, newFolders <= limits.planNewFolders else { throw AgentToolCode.too_many }

        for entry in kept {
            let item = try await planItem(entry.record)
            switch entry.ask {
            case .move(let target): steps.append(.move(item, to: target))
            case .copy(let target): steps.append(.copy(item, to: target))
            case .rename(let name): steps.append(.rename(item, to: name))
            case .trash: steps.append(.trash(item))
            }
        }
        return steps
    }

    // MARK: New folders

    private func newFolder(_ folder: AgentProposedChanges.NewFolder) async throws -> AgentPlanStep? {
        // Where it is made: an existing folder (`anchor`), or a new folder (`parentKey`) somewhere below one.
        let target: AgentPlanTarget, anchor: AgentHandleRecord, depth: Int, parentKey: String?
        if Self.isKey(folder.parent) {
            if let code = lostKeys[folder.parent] { return lose(folder.key, code) }
            // A key must be declared before it is used.
            guard let above = keys[folder.parent] else { return lose(folder.key, .unknown_id) }
            target = above.target; anchor = above.anchor; depth = above.depth
            if case .new(let key) = above.target { parentKey = key } else { parentKey = nil }
        } else {
            switch try await destinationFolder(folder.parent) {
            case .failure(let code): return lose(folder.key, code)
            case .success(let record):
                target = .existing(Self.planItem(record)); anchor = record; depth = 0; parentKey = nil
            }
        }
        guard depth < AgentLimits.newFolderLevels else { return lose(folder.key, .limit_reached) }
        let name: ValidFileName
        switch AgentNewName.validateFolderName(folder.name, existing: nil) {
        case .failure(let code): return lose(folder.key, code)
        case .success(let valid): name = valid
        }
        let clash = AgentNewName.clashKey(name.value)

        if parentKey == nil {
            // A folder of that name is already there: the key is that folder, admitted through the scope, and
            // nothing is made. Anything else of that name means the name is taken.
            if let found = try await child(named: clash, in: anchor) {
                guard found.kind == .directory else { return lose(folder.key, .name_taken) }
                switch await scope.admit(childNamed: found.name, in: anchor) {
                case .failure(let code):
                    try Self.endIfQuiet(code)
                    return lose(folder.key, code)
                case .success(let record):
                    if let problem = folderProblem(record) { return lose(folder.key, problem) }
                    keys[folder.key] = NewKey(target: .existing(Self.planItem(record)), depth: 0, anchor: record,
                                              parentKey: nil, name: name)
                    return nil
                }
            }
        }
        // Two new folders of one name in one folder are one folder.
        if let sibling = keys.values.first(where: {
            $0.depth == depth + 1 && $0.parentKey == parentKey && $0.anchor.path == anchor.path
                && AgentNewName.clashKey($0.name.value) == clash
        }) {
            keys[folder.key] = sibling
            return nil
        }
        keys[folder.key] = NewKey(target: .new(key: folder.key), depth: depth + 1, anchor: anchor, parentKey: parentKey,
                                  name: name)
        return .newFolder(key: folder.key, parent: target, name: name)
    }

    private func lose(_ key: String, _ code: AgentToolCode) -> AgentPlanStep? {
        lostKeys[key] = code
        count(code)
        return nil
    }

    // MARK: Moves and copies

    private func transferAsks(_ transfer: AgentProposedChanges.Transfer,
                              isCopy: Bool) async throws -> [(record: AgentHandleRecord, ask: Ask)] {
        let entries = transfer.items.count + (transfer.allIn.isEmpty ? 0 : 1)
        // Where it goes: a key declared earlier, or a folder.
        let target: AgentPlanTarget, destination: AgentHandleRecord
        if Self.isKey(transfer.to) {
            if let code = lostKeys[transfer.to] { count(code, times: entries); return [] }
            guard let key = keys[transfer.to] else { count(.unknown_id, times: entries); return [] }
            target = key.target
            destination = key.anchor
        } else {
            switch try await destinationFolder(transfer.to) {
            case .failure(let code):
                count(code, times: code == .not_loaded ? 1 : entries)
                return []
            case .success(let record):
                target = .existing(Self.planItem(record))
                destination = record
            }
        }

        var sources: [AgentHandleRecord] = []
        for handle in transfer.items {
            if let record = try await source(handle) { sources.append(record) }
        }
        if !transfer.allIn.isEmpty { sources += try await everything(in: transfer.allIn) }

        var asks: [(record: AgentHandleRecord, ask: Ask)] = []
        var inThisStep: Set<String> = []
        for record in sources where inThisStep.insert(Self.identityKey(record)).inserted {
            // A folder can't go into itself or into anything inside it.
            if Self.isSame(destination, record) || Self.isInside(destination.path, record.path) {
                count(.not_allowed)
                continue
            }
            // A move into the folder an item is already in does nothing.
            if !isCopy, case .existing(let folder) = target, folder.path == AgentPlanChart.parent(of: record.path) { continue }
            asks.append((record, isCopy ? .copy(target) : .move(target)))
        }
        return asks
    }

    /// Everything directly inside a folder, as the scope lists it now.
    private func everything(in handle: String) async throws -> [AgentHandleRecord] {
        let folder: AgentHandleRecord
        switch try await destinationFolder(handle) {
        case .failure(let code): count(code); return []
        case .success(let record): folder = record
        }
        let listing = await scope.children(of: folder, limit: limits.planSteps + 1)
        switch listing.state {
        case .ok: break
        case .notLoaded: count(.not_loaded); return []
        case .denied: count(.not_allowed); return []
        case .gone: count(.not_found); return []
        case .slow: throw AgentToolCode.not_responding
        }
        if listing.more > 0 || listing.records.count > limits.planSteps { throw AgentToolCode.too_many }
        var sources: [AgentHandleRecord] = []
        for record in listing.records {
            if let problem = await sourceProblem(record) { count(problem) } else { sources.append(record) }
        }
        return sources
    }

    // MARK: Resolving

    private func resolve(_ handle: String) async throws -> Result<AgentHandleRecord, AgentToolCode> {
        if let known = resolved[handle] { return known }
        let result: Result<AgentHandleRecord, AgentToolCode>
        if let record = await scope.record(for: handle) {
            if let code = await scope.recheck(record) {
                try Self.endIfQuiet(code)
                result = .failure(code)
            } else {
                result = .success(record)
            }
        } else {
            result = .failure(await scope.isRetired(handle) ? .stale_id : .unknown_id)
        }
        resolved[handle] = result
        return result
    }

    /// An item a step changes, or nil when it was left out and counted.
    private func source(_ handle: String) async throws -> AgentHandleRecord? {
        switch try await resolve(handle) {
        case .failure(let code):
            count(code)
            return nil
        case .success(let record):
            if let problem = await sourceProblem(record) { count(problem); return nil }
            return record
        }
    }

    /// Why an item can't be changed: it is a root, told by identity so a second handle to a root is still one, or
    /// it is a folder macOS asks about before letting an app in.
    private func sourceProblem(_ record: AgentHandleRecord) async -> AgentToolCode? {
        if record.isRoot || record.isProtectedLeaf { return .not_allowed }
        if await scope.isRoot(identity: record.identity, path: record.path) { return .not_allowed }
        return nil
    }

    /// A folder something goes into, a new folder is made in, or everything is taken from.
    private func destinationFolder(_ handle: String) async throws -> Result<AgentHandleRecord, AgentToolCode> {
        switch try await resolve(handle) {
        case .failure(let code): return .failure(code)
        case .success(let record):
            if let problem = folderProblem(record) { return .failure(problem) }
            return .success(record)
        }
    }

    /// Why a record can't stand where a folder belongs: a file, a package or a link; a folder macOS asks about; or
    /// one whose names aren't loaded from its cloud.
    private func folderProblem(_ record: AgentHandleRecord) -> AgentToolCode? {
        guard record.kind == .directory, !record.isProtectedLeaf else { return .not_allowed }
        return record.isDataless ? .not_loaded : nil
    }

    /// The item in a folder whose name clashes with `clash`, read from the folder itself.
    private func child(named clash: String, in folder: AgentHandleRecord) async throws -> AgentDiskItem? {
        if names[folder.path] == nil {
            let listing = await disk.list(folder.path, limit: limits.entriesPerRequest, idleSeconds: limits.listSeconds)
            if listing.state == .slow { throw AgentToolCode.not_responding }
            names[folder.path] = listing.items
        }
        return names[folder.path]?.first { AgentNewName.clashKey($0.name) == clash }
    }

    /// The plan's copy of an item. A folder carries how many items it holds directly, up to `AgentLimits.holdsCap`.
    private func planItem(_ record: AgentHandleRecord) async throws -> AgentPlanItem {
        guard record.kind == .directory, !record.isDataless else { return Self.planItem(record) }
        let listing = await disk.list(record.path, limit: AgentLimits.holdsCap, idleSeconds: limits.listSeconds)
        let holds = listing.state == .ok
            ? min(AgentLimits.holdsCap, listing.items.filter { AgentItemFilter.isListable(name: $0.name, isHidden: $0.isHidden) }.count + listing.more)
            : nil
        return Self.planItem(record, holds: holds)
    }

    private static func planItem(_ record: AgentHandleRecord, holds: Int? = nil) -> AgentPlanItem {
        AgentPlanItem(handle: record.handle, rootAlias: record.rootAlias, path: record.path, name: record.name,
                      kind: record.kind, identity: record.identity, isDataless: record.isDataless, holds: holds)
    }

    // MARK: Small pieces

    private func count(_ code: AgentToolCode, times: Int = 1) {
        if times > 0 { tally[code, default: 0] += times }
    }

    /// A place that stops answering ends the whole call; there is no retry.
    private static func endIfQuiet(_ code: AgentToolCode) throws {
        if code == .not_responding || code == .disconnected { throw code }
    }

    private static func identityKey(_ record: AgentHandleRecord) -> String {
        record.identity.map { "id:" + $0.scope + "\u{1F}" + $0.object } ?? "path:" + record.path
    }

    private static func isSame(_ one: AgentHandleRecord, _ other: AgentHandleRecord) -> Bool {
        identityKey(one) == identityKey(other) || one.path == other.path
    }

    /// Whether `path` is inside `folder`, by whole path components.
    private static func isInside(_ path: String, _ folder: String) -> Bool {
        let parts = path.split(separator: "/"), folderParts = folder.split(separator: "/")
        return parts.count > folderParts.count && Array(parts.prefix(folderParts.count)) == folderParts
    }
}
