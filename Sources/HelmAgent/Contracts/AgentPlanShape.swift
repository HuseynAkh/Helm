import Foundation
import HelmCore

// What a plan's card reads from the plan: its words, its counts, which groups start ticked and which notes show.
// All of it is worked out from the checked steps alone.

extension AgentPlanTitle {
    /// The plan's name on its card. It is also the name of the history group, so the Edit menu reads "Undo" and
    /// then these words.
    public var text: String {
        switch self {
        case .organize(let rootLabel): return AgentText.planTitleOrganize(rootLabel)
        case .move(let count): return AgentText.planTitleMove(count)
        case .copy(let count): return AgentText.planTitleCopy(count)
        case .rename(let count): return AgentText.planTitleRename(count)
        case .trash(let count): return AgentText.planTitleTrash(count)
        case .create(let count): return AgentText.planTitleCreate(count)
        }
    }
}

extension AgentPlanNotice {
    /// Which of a card's three lines the notice belongs to: 1 for what was left out, 2 for what can't be undone,
    /// 3 for what syncs or is shared.
    public var slot: Int {
        switch self {
        case .notAllowed, .notDownloaded, .foldersNotLoaded, .noTrash, .readOnly, .leftOutSeveral: return 1
        case .cantUndo: return 2
        case .syncs, .shared, .syncsMaybeShared: return 3
        }
    }

    public var text: String {
        switch self {
        case .notAllowed(let count): return AgentText.noteNotAllowed(count)
        case .notDownloaded(let count): return AgentText.noteNotDownloaded(count)
        case .foldersNotLoaded(let count): return AgentText.noticeFoldersNotLoaded(count)
        case .noTrash(let place): return AgentText.noteNoTrash(place)
        case .readOnly(let place): return AgentText.noteReadOnly(place)
        case .leftOutSeveral(let count): return AgentText.noteLeftOutSeveral(count)
        case .cantUndo(let place): return AgentText.noteCantUndo(place)
        case .syncs: return AgentText.noteSyncs
        case .shared(let place): return AgentText.noteShared(place)
        case .syncsMaybeShared: return AgentText.noteSyncsMaybeShared
        }
    }

    /// Which of the slot 3 lines is shown when a plan carries more than one: the one that says the most.
    fileprivate var reach: Int {
        switch self {
        case .shared: return 3
        case .syncsMaybeShared: return 2
        case .syncs: return 1
        default: return 0
        }
    }

    /// How many changes a slot 1 notice stands for. A place without a Trash, or one that can only be viewed, names
    /// no number, so it counts once.
    fileprivate var leftOutCount: Int {
        switch self {
        case .notAllowed(let count), .notDownloaded(let count), .foldersNotLoaded(let count), .leftOutSeveral(let count):
            return max(0, count)
        default: return 1
        }
    }
}

extension AgentPlanCounts {
    public var total: Int { moves + copies + newFiles + newFolders + renames + trash }

    /// The kinds that aren't zero, joined by a middle dot: "214 moves · 6 new folders · 3 renames".
    public var line: String {
        var parts: [String] = []
        if moves != 0 { parts.append(AgentText.countMoves(moves)) }
        if copies != 0 { parts.append(AgentText.countCopies(copies)) }
        if newFiles != 0 { parts.append(AgentText.countNewFiles(newFiles)) }
        if newFolders != 0 { parts.append(AgentText.countNewFolders(newFolders)) }
        if renames != 0 { parts.append(AgentText.countRenames(renames)) }
        if trash != 0 { parts.append(AgentText.countTrash(trash)) }
        return parts.joined(separator: " · ")
    }
}

extension AgentChangePlan {
    /// The groups whose tick starts on: every group with no guard.
    public var defaultTicked: Set<Int> { Set(groups.filter(\.startsOn).map(\.id)) }

    /// What the plan does with these groups ticked. A new folder counts only when something ticked needs it: it is
    /// in a ticked group of new folders, a ticked step goes into it or is made in it, or a folder that counts is made
    /// inside it.
    public func counts(ticked: Set<Int>) -> AgentPlanCounts {
        var counts = AgentPlanCounts()
        var needed: Set<String> = []
        var folders: [String: AgentPlanTarget] = [:]
        for step in steps {
            if case .newFolder(let key, let parent, _) = step { folders[key] = parent }
        }
        for group in groups where ticked.contains(group.id) {
            for index in group.steps where steps.indices.contains(index) {
                switch steps[index] {
                case .newFolder(let key, _, _):
                    if group.kind == .newFolders { needed.insert(key) }
                case .move(_, let target):
                    counts.moves += 1
                    if case .new(let key) = target { needed.insert(key) }
                case .copy(_, let target):
                    counts.copies += 1
                    if case .new(let key) = target { needed.insert(key) }
                case .newFile(let parent, _, _):
                    counts.newFiles += 1
                    if case .new(let key) = parent { needed.insert(key) }
                case .rename:
                    counts.renames += 1
                case .trash:
                    counts.trash += 1
                }
            }
        }
        // A needed folder needs the new folder it is made in, and so on up.
        var pending = Array(needed)
        while let key = pending.popLast() {
            if case .new(let parent)? = folders[key], needed.insert(parent).inserted { pending.append(parent) }
        }
        counts.newFolders = needed.filter { folders[$0] != nil }.count
        return counts
    }

    /// Whether every id in `ticked` is a group of this plan.
    public func isTickSet(_ ticked: Set<Int>) -> Bool { ticked.isSubset(of: Set(groups.map(\.id))) }

    /// The notes a card shows: three at most, one a slot, in slot order. Several slot 1 notices fold into one line
    /// that says how many changes were left out in all. Of the slot 3 lines the one that says the most is shown.
    public var cardNotes: [AgentPlanNotice] {
        var notes: [AgentPlanNotice] = []
        let leftOutNotes = notices.filter { $0.slot == 1 }
        if leftOutNotes.count == 1 {
            notes.append(leftOutNotes[0])
        } else if leftOutNotes.count > 1 {
            let counted = leftOut.values.reduce(0) { $0 + max(0, $1) }
            notes.append(.leftOutSeveral(counted > 0 ? counted : leftOutNotes.reduce(0) { $0 + $1.leftOutCount }))
        }
        if let note = notices.first(where: { $0.slot == 2 }) { notes.append(note) }
        // The first of the strongest, so the answer doesn't depend on the order two equal notes arrived in.
        var widest: AgentPlanNotice?
        for note in notices where note.slot == 3 && note.reach > (widest?.reach ?? 0) { widest = note }
        if let widest { notes.append(widest) }
        return notes
    }

    /// A plan with no steps.
    public var isEmpty: Bool { steps.isEmpty }

    /// Whether the card says that everything is already in place: the plan is empty and nothing was left out.
    /// When something was left out, the card says that and nothing else.
    public var showsNothingToDo: Bool {
        isEmpty && leftOut.values.allSatisfy { $0 <= 0 } && !notices.contains { $0.slot == 1 }
    }
}

extension AgentProposedChanges {
    /// A tool call's arguments, read exactly as the schema has them. Nil when a property is missing, one is there
    /// that the schema doesn't have, or a value is of the wrong kind. Nothing is guessed or filled in.
    public static func decodeStrictly(_ arguments: Data) -> AgentProposedChanges? {
        guard let json = try? AgentJSON(data: arguments),
              let top = members(of: json, exactly: ["new_folders", "new_files", "moves", "copies", "renames", "trash"]),
              let newFolders = each(top["new_folders"], { item -> NewFolder? in
                  guard let fields = members(of: item, exactly: ["key", "parent", "name"]), let key = fields["key"]?.stringValue,
                        let parent = fields["parent"]?.stringValue, let name = fields["name"]?.stringValue else { return nil }
                  return NewFolder(key: key, parent: parent, name: name)
              }),
              let newFiles = each(top["new_files"], { item -> NewFile? in
                  guard let fields = members(of: item, exactly: ["parent", "name", "text"]),
                        let parent = fields["parent"]?.stringValue, let name = fields["name"]?.stringValue,
                        let text = fields["text"]?.stringValue else { return nil }
                  return NewFile(parent: parent, name: name, text: text)
              }),
              let moves = each(top["moves"], transfer), let copies = each(top["copies"], transfer),
              let renames = each(top["renames"], { item -> Rename? in
                  guard let fields = members(of: item, exactly: ["item", "name"]), let handle = fields["item"]?.stringValue,
                        let name = fields["name"]?.stringValue else { return nil }
                  return Rename(item: handle, name: name)
              }),
              let trash = each(top["trash"], { $0.stringValue }) else { return nil }
        return AgentProposedChanges(newFolders: newFolders, newFiles: newFiles, moves: moves, copies: copies, renames: renames,
                                    trash: trash)
    }

    private static func transfer(_ item: AgentJSON) -> Transfer? {
        guard let fields = members(of: item, exactly: ["items", "all_in", "to"]),
              let items = each(fields["items"], { $0.stringValue }), let allIn = fields["all_in"]?.stringValue,
              let to = fields["to"]?.stringValue else { return nil }
        return Transfer(items: items, allIn: allIn, to: to)
    }

    /// An object's members, when it has exactly these keys.
    private static func members(of json: AgentJSON, exactly keys: Set<String>) -> [String: AgentJSON]? {
        guard let members = json.objectValue, Set(members.keys) == keys else { return nil }
        return members
    }

    /// Every element of an array read by `element`. Nil when the value isn't an array or any element isn't read.
    private static func each<Value>(_ json: AgentJSON?, _ element: (AgentJSON) -> Value?) -> [Value]? {
        guard let items = json?.arrayValue else { return nil }
        var values: [Value] = []
        values.reserveCapacity(items.count)
        for item in items {
            guard let value = element(item) else { return nil }
            values.append(value)
        }
        return values
    }
}
