import Foundation
import HelmCore

/// What running one tool call came to: the JSON of its result and how many names it holds, a code for what went
/// wrong, or a plan Helm checked and now holds for the person.
public enum AgentToolOutcome: Sendable { case result(json: String, names: Int), error(AgentToolCode), plan(AgentChangePlan) }

/// Runs the three tools for one request. Arguments are read exactly as the schemas give them; an unknown or a
/// missing field is `bad_arguments`. Existing items are named only by handles, so a path or `~` where an id belongs
/// is an id Helm never issued. What goes back is JSON Helm builds from what the disk answered: names pass the
/// escaper, sizes are rounded to two figures, and nothing inside a file is ever read.
///
/// A runner counts what it sends for the request it was made for, so a session makes one runner per request.
public struct AgentToolRunner: Sendable {
    private let scope: AgentScope
    private let disk: any AgentDisk
    private let validator: any AgentPlanValidating
    private let limits: AgentLimits
    private let tally = Tally()

    public init(scope: AgentScope, disk: any AgentDisk, validator: any AgentPlanValidating, limits: AgentLimits) {
        self.scope = scope
        self.disk = disk
        self.validator = validator
        self.limits = limits
    }

    /// Runs one call. `selectedPaths` are the tab's selection, marked as selected in listings and never sent.
    public func run(_ call: AgentToolCall, selectedPaths: Set<String>) async -> AgentToolOutcome {
        guard AgentToolCatalog.names.contains(call.name) else { return .error(.unknown_tool) }
        switch call.name {
        case Self.listFolderName: return await listFolder(call.arguments, selected: Selection(selectedPaths))
        case Self.findItemsName: return await findItems(call.arguments, selected: Selection(selectedPaths))
        default: return await proposeChanges(call.arguments)
        }
    }

    // MARK: What the session reads after each call

    /// Names sent in this request so far.
    var namesSent: Int { tally.value { $0.names } }
    /// Folders left out because their names aren't loaded, and children whose details couldn't be read.
    var notLoaded: Int { tally.value { $0.notLoaded } }
    /// The label of a root whose place stopped answering during this request.
    var slowRoot: String? { tally.value { $0.slowRoot } }

    // MARK: list_folder

    private func listFolder(_ arguments: Data, selected: Selection) async -> AgentToolOutcome {
        guard let fields = Self.fields(of: arguments, exactly: ["folder", "depth", "after"]),
              let folderID = fields["folder"]?.stringValue, let after = fields["after"]?.stringValue,
              let depth = Self.integer(fields["depth"]), (0...Self.deepest).contains(depth) else { return .error(.bad_arguments) }
        let folder: AgentHandleRecord
        switch await enterableFolder(folderID) {
        case .failure(let code): return .error(code)
        case .success(let found): folder = found
        }
        let facts = await scope.facts(forFolderAt: folder.path)
        let limits = self.limits(for: facts.kind)
        let budget = limits.entriesPerRequest - namesSent
        guard budget > 0 else { return .error(.limit_reached) }
        let levels = depth == 0 ? limits.maxDepth : min(depth, limits.maxDepth)
        var walk = Walk(bound: limits.entriesPerRequest + 1)
        let state = await self.walk(folder, levels: levels, limits: limits, into: &walk)
        // A root dropped while the disk answered takes its listing with it.
        guard let root = await scope.root(alias: folder.rootAlias) else { return .error(.stale_id) }
        switch state {
        case .denied: return .error(.not_allowed)
        case .gone: return .error(.not_found)
        case .notLoaded: return .error(.not_loaded)
        case .slow, .ok: break
        }
        if walk.isSlow { await noteSlow(folder) }
        var start = 0
        if !after.isEmpty {
            guard let index = walk.entries.firstIndex(where: { $0.record.handle == after }) else {
                // An id of something else isn't a place in this listing; one never issued is unknown.
                return .error(await scope.record(for: after) == nil ? await unknownCode(after) : .bad_arguments)
            }
            start = index + 1
        }
        let pageSize = min(limits.entriesPerPage, budget)
        let page = Array(walk.entries[min(start, walk.entries.count)..<min(start + pageSize, walk.entries.count)])
        let more = walk.entries.count - start - page.count + walk.moreOnDisk
        let cutByBudget = budget < limits.entriesPerPage && more > 0
        let items = page.map { entry in
            item(entry.record, entry.item, in: entry.parent, holds: walk.holds[entry.record.handle], selected: selected)
        }
        tally.change { $0.names += page.count; $0.notLoaded += walk.notLoaded }
        let json = AgentJSON.object([
            "source": .string("folder_listing"), "folder": .string(folder.handle), "root": .string(folder.rootAlias),
            "name": .string(AgentTextEscaper.escape(folder.isRoot ? root.modelName : folder.name)),
            "place": .string(facts.modelWord), "items": .array(items), "more": .number(Double(max(0, more))),
            "not_loaded": .number(Double(walk.notLoaded)),
            "partial": .string(walk.isSlow ? Self.partialSlow : (walk.isCut || cutByBudget ? Self.partialLimit : Self.partialNone))
        ])
        return .result(json: Self.text(json), names: page.count)
    }

    // MARK: find_items

    private func findItems(_ arguments: Data, selected: Selection) async -> AgentToolOutcome {
        let keys: Set<String> = ["folder", "name_any", "kinds", "modified_from", "modified_to", "min_bytes", "max_bytes"]
        guard let fields = Self.fields(of: arguments, exactly: keys), let folderID = fields["folder"]?.stringValue,
              let words = Self.strings(fields["name_any"]), let kindWords = Self.strings(fields["kinds"]),
              let from = fields["modified_from"]?.stringValue, let to = fields["modified_to"]?.stringValue,
              Self.isDay(from), Self.isDay(to),
              let minBytes = Self.integer(fields["min_bytes"]), let maxBytes = Self.integer(fields["max_bytes"]),
              minBytes >= 0, maxBytes >= 0 else { return .error(.bad_arguments) }
        var kinds: [AISearchKind] = []
        for word in kindWords {
            guard let kind = AISearchKind(rawValue: word) else { return .error(.bad_arguments) }
            kinds.append(kind)
        }
        let folder: AgentHandleRecord
        switch await enterableFolder(folderID) {
        case .failure(let code): return .error(code)
        case .success(let found): folder = found
        }
        let facts = await scope.facts(forFolderAt: folder.path)
        let limits = self.limits(for: facts.kind)
        let budget = min(limits.findResults, limits.entriesPerRequest - namesSent)
        guard budget > 0 else { return .error(.limit_reached) }
        var walk = Walk(bound: limits.entriesPerRequest)
        let state = await self.walk(folder, levels: limits.maxDepth, limits: limits, into: &walk)
        guard await scope.root(alias: folder.rootAlias) != nil else { return .error(.stale_id) }
        switch state {
        case .denied: return .error(.not_allowed)
        case .gone: return .error(.not_found)
        case .notLoaded: return .error(.not_loaded)
        case .slow, .ok: break
        }
        if walk.isSlow { await noteSlow(folder) }
        let terms = words.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let matches = walk.entries.filter { entry in
            let item = entry.item, isFolder = item.kind == .directory
            if !terms.isEmpty, !terms.contains(where: { item.name.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive]) != nil }) {
                return false
            }
            if !kinds.isEmpty {
                guard let kind = Self.searchKind(of: item), kinds.contains(where: { $0.covers(kind) }) else { return false }
            }
            let day = Self.day(item.modified)
            if !from.isEmpty, day < from { return false }
            if !to.isEmpty, day > to { return false }
            if minBytes > 0, isFolder || item.size < Int64(minBytes) { return false }
            if maxBytes > 0, isFolder || item.size > Int64(maxBytes) { return false }
            return true
        }
        let page = Array(matches.prefix(budget))
        let items = page.map { item($0.record, $0.item, in: $0.parent, holds: nil, selected: selected) }
        tally.change { $0.names += page.count; $0.notLoaded += walk.notLoaded }
        let json = AgentJSON.object([
            "source": .string("found_items"), "folder": .string(folder.handle), "items": .array(items),
            "more": .number(Double(matches.count - page.count)), "not_loaded": .number(Double(walk.notLoaded)),
            "partial": .string(walk.isSlow ? Self.partialSlow : (walk.isCut ? Self.partialLimit : Self.partialNone))
        ])
        return .result(json: Self.text(json), names: page.count)
    }

    // MARK: propose_changes

    private func proposeChanges(_ arguments: Data) async -> AgentToolOutcome {
        guard let proposal = AgentProposedChanges.decodeStrictly(arguments) else { return .error(.bad_arguments) }
        switch await validator.validate(proposal, scope: scope, disk: disk, limits: limits) {
        case .plan(let plan):
            return .plan(plan)
        case .refused(let code):
            return .error(code)
        case .nothingToDo(let leftOut):
            var members: [String: AgentJSON] = ["source": .string("plan"), "status": .string("nothing_to_do")]
            members["left_out"] = Self.leftOut(leftOut)
            return .result(json: Self.text(.object(members)), names: 0)
        }
    }

    /// Counts by code, in the order of the codes, for a plan's result.
    static func leftOut(_ counts: [AgentToolCode: Int]) -> AgentJSON {
        .array(AgentToolCode.allCases.compactMap { code in
            guard let count = counts[code], count > 0 else { return nil }
            return .object(["code": .string(code.rawValue), "count": .number(Double(count))])
        })
    }

    // MARK: Walking

    private struct Walk {
        var entries: [(record: AgentHandleRecord, item: AgentDiskItem, parent: String)] = []
        /// Item counts of the folders whose children this walk listed.
        var holds: [String: Int] = [:]
        var moreOnDisk = 0
        var notLoaded = 0
        var isSlow = false
        /// A limit cut the walk short.
        var isCut = false
        let bound: Int
        init(bound: Int) { self.bound = bound }
    }

    /// Walks `folder` and the folders below it, `levels` deep, each folder followed by what is in it. A leaf, a
    /// link, a package and a folder that isn't loaded are listed and never entered. Answers how the top folder's own
    /// listing went.
    private func walk(_ folder: AgentHandleRecord, levels: Int, limits: AgentLimits, into walk: inout Walk) async -> AgentDiskListState {
        let listed = await scope.listing(of: folder, limit: max(1, walk.bound - walk.entries.count), idleSeconds: limits.listSeconds,
                                         recheckingFirst: false)
        switch listed.state {
        case .ok: break
        case .slow:
            walk.isSlow = true
            return .slow
        case .denied, .gone, .notLoaded:
            return listed.state
        }
        walk.notLoaded += listed.unreadable
        walk.moreOnDisk += listed.more
        if listed.more > 0 || listed.outOfHandles { walk.isCut = true }
        walk.holds[folder.handle] = listed.entries.count + listed.more
        for entry in listed.entries {
            guard walk.entries.count < walk.bound else {
                walk.isCut = true
                break
            }
            walk.entries.append((entry.record, entry.item, folder.handle))
            let record = entry.record
            guard levels > 1, record.kind == .directory, !record.isProtectedLeaf else { continue }
            if record.isDataless {
                walk.notLoaded += 1
                continue
            }
            switch await self.walk(record, levels: levels - 1, limits: limits, into: &walk) {
            case .slow:
                walk.isSlow = true
            case .notLoaded:
                walk.notLoaded += 1
            case .ok, .denied, .gone:
                break
            }
        }
        return .ok
    }

    /// The folder an id names, checked against the disk, when a listing may enter it.
    private func enterableFolder(_ id: String) async -> Result<AgentHandleRecord, AgentToolCode> {
        guard let record = await scope.record(for: id) else { return .failure(await unknownCode(id)) }
        switch record.kind {
        case .directory: break
        case .symlinkToDirectory, .symlinkToFile, .danglingSymlink, .alias: return .failure(.link)
        case .package: return .failure(.inside_package)
        case .regular, .other: return .failure(.not_allowed)
        }
        // A folder macOS refused, or one that is never entered, answers without the disk being asked again.
        let refused = await scope.isRefused(record.path)
        if record.isProtectedLeaf || refused { return .failure(.not_allowed) }
        if record.isDataless { return .failure(.not_loaded) }
        if let code = await scope.recheck(record) { return .failure(code) }
        return .success(record)
    }

    private func unknownCode(_ id: String) async -> AgentToolCode {
        await scope.isRetired(id) ? .stale_id : .unknown_id
    }

    /// Keeps the label of the root whose place stopped answering, for the line that ends the request.
    private func noteSlow(_ folder: AgentHandleRecord) async {
        let label = await scope.root(alias: folder.rootAlias)?.label ?? folder.name
        tally.change { $0.slowRoot = $0.slowRoot ?? label }
    }

    private func limits(for kind: StorageKind) -> AgentLimits {
        var limits = self.limits.adjusted(for: kind)
        if let seconds = tally.value({ $0.listSeconds }) { limits = limits.scaled(listSeconds: seconds) }
        return limits
    }

    /// Listings use these seconds without progress, in place of the usual limits: what a fixture run asks for.
    func usingListSeconds(_ seconds: Double?) -> AgentToolRunner {
        tally.change { $0.listSeconds = seconds }
        return self
    }

    // MARK: Entries

    private func item(_ record: AgentHandleRecord, _ item: AgentDiskItem, in parent: String, holds: Int?, selected: Selection) -> AgentJSON {
        var members: [String: AgentJSON] = [
            "id": .string(record.handle), "in": .string(parent), "name": .string(AgentTextEscaper.escape(record.name)),
            "kind": .string(Self.kindWord(of: item)), "modified": .string(Self.day(record.modified))
        ]
        if record.kind == .regular || record.kind == .package {
            members["bytes"] = .number(Double(AgentItemFilter.roundedBytes(record.size)))
        }
        if let holds { members["holds"] = .number(Double(holds)) }
        if record.isDataless { members["cloud"] = .bool(true) }
        if selected.contains(record.path) { members["selected"] = .bool(true) }
        if let place = item.place { members["place"] = .string(place.modelWord) }
        return .object(members)
    }

    static func kindWord(of item: AgentDiskItem) -> String {
        switch item.kind {
        case .symlinkToDirectory, .symlinkToFile, .danglingSymlink, .alias: return "link"
        default: return searchKind(of: item)?.rawValue ?? "other"
        }
    }

    private static func searchKind(of item: AgentDiskItem) -> AISearchKind? {
        let dot = item.name.lastIndex(of: ".")
        let ext = dot.map { String(item.name[item.name.index(after: $0)...]) } ?? ""
        return AISearchKind.of(typeIdentifier: item.typeIdentifier, extension: ext, kind: item.kind)
    }

    /// A date as YYYY-MM-DD in the Mac's time zone.
    static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Empty, or a real day written YYYY-MM-DD.
    private static func isDay(_ text: String) -> Bool {
        if text.isEmpty { return true }
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard text.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return DateComponents(calendar: calendar, year: year, month: month, day: day).isValidDate(in: calendar)
    }

    // MARK: Reading arguments

    /// An object's members, when the arguments are an object with exactly these keys.
    private static func fields(of arguments: Data, exactly keys: Set<String>) -> [String: AgentJSON]? {
        guard let json = try? AgentJSON(data: arguments), let members = json.objectValue, Set(members.keys) == keys else { return nil }
        return members
    }

    /// A whole number, written as JSON numbers are.
    private static func integer(_ json: AgentJSON?) -> Int? {
        guard let value = json?.numberValue, value == value.rounded(), abs(value) <= 1e15 else { return nil }
        return Int(value)
    }

    private static func strings(_ json: AgentJSON?) -> [String]? {
        guard let values = json?.arrayValue else { return nil }
        var strings: [String] = []
        for value in values {
            guard let text = value.stringValue else { return nil }
            strings.append(text)
        }
        return strings
    }

    static func text(_ json: AgentJSON) -> String { String(decoding: json.data(), as: UTF8.self) }

    static let listFolderName = "list_folder"
    static let findItemsName = "find_items"
    static let proposeChangesName = "propose_changes"
    private static let deepest = 8
    private static let partialNone = "none", partialSlow = "slow", partialLimit = "limit"

    // MARK: Parts

    /// The tab's selection, compared the way paths are.
    private struct Selection {
        let keys: Set<[[UInt8]]>
        init(_ paths: Set<String>) { keys = Set(paths.map(AgentPathParts.comparable)) }
        func contains(_ path: String) -> Bool { !keys.isEmpty && keys.contains(AgentPathParts.comparable(path)) }
    }

    /// What one request has sent and found. Reads and writes hold the lock.
    private final class Tally: @unchecked Sendable {
        struct Counts {
            var names = 0, notLoaded = 0
            var slowRoot: String?
            var listSeconds: Double?
        }
        private let lock = NSLock()
        private var counts = Counts()
        func value<Value>(_ body: (Counts) -> Value) -> Value {
            lock.lock()
            defer { lock.unlock() }
            return body(counts)
        }
        func change(_ body: (inout Counts) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            body(&counts)
        }
    }
}
