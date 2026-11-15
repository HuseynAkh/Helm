#if os(macOS)
import SwiftUI
import HelmAgent
import HelmCore

/// A plan the person approved: its id and the groups they left ticked. Only this file can make one, and only from
/// the card's Apply, so nothing else can approve a plan on the person's behalf.
struct AgentApprovedPlan {
    let planID: UUID
    let ticked: Set<Int>
    fileprivate init(tickedByPerson ticked: Set<Int>, planID: UUID) {
        self.planID = planID; self.ticked = ticked
    }
}

/// A checked plan as its card shows it: the groups and which are ticked, what the plan does with those ticks, its
/// notes, and how far it has got. Every word on it is Helm's own, worked out from the checked steps; names from the
/// disk are shown escaped.
struct AgentPlanCard: Equatable {
    enum Stage: Equatable {
        /// Waiting for the person: Apply or Cancel.
        case open
        /// Being applied; the line says how far it has got.
        case applying(String)
        case applied
        case dismissed
        /// A later plan took its place.
        case replaced
    }

    private(set) var plan: AgentChangePlan
    private(set) var ticked: Set<Int>
    /// Groups opened to their full list. A group that starts unticked starts open, so its items are seen, unless it
    /// is long enough to push Cancel and Apply out of reach.
    private(set) var opened: Set<Int>
    var stage: Stage = .open
    /// Apply found that the folder had changed, so this is a new plan for the person to look at again.
    private(set) var wasRefreshed = false
    /// A refreshed card answers no key until the person has looked at it: a tick, a group opened or shut, or a click
    /// on Apply. A second Command-Return pressed straight after the first, or a held key, applies nothing.
    private(set) var holdsKeyedApply = false
    /// The folders of the conversation when the plan arrived, to say where each item is now.
    let roots: [AgentScopeRoot]

    init(plan: AgentChangePlan, roots: [AgentScopeRoot]) {
        self.plan = plan
        self.roots = roots
        ticked = plan.defaultTicked
        opened = Self.startsOpen(plan)
    }

    /// The most rows a group that starts unticked shows before it is opened.
    static let openRows = 10
    private static func startsOpen(_ plan: AgentChangePlan) -> Set<Int> {
        Set(plan.groups.filter { !$0.startsOn && $0.steps.count <= openRows }.map(\.id))
    }

    /// The approval of exactly what is ticked on this card now.
    func approval() -> AgentApprovedPlan { AgentApprovedPlan(tickedByPerson: ticked, planID: plan.id) }

    /// The plan Apply found had changed. Its ticks start where a new card's do, with the guarded groups off.
    mutating func refresh(with plan: AgentChangePlan) {
        self.plan = plan
        ticked = plan.defaultTicked
        opened = Self.startsOpen(plan)
        stage = .open
        wasRefreshed = true
        holdsKeyedApply = true
    }

    mutating func toggle(_ group: Int) {
        guard stage == .open, plan.groups.contains(where: { $0.id == group }) else { return }
        if ticked.contains(group) { ticked.remove(group) } else { ticked.insert(group) }
        holdsKeyedApply = false
    }

    mutating func toggleOpen(_ group: Int) {
        if opened.contains(group) { opened.remove(group) } else { opened.insert(group) }
        holdsKeyedApply = false
    }

    var title: String { plan.title.text }
    var countsLine: String { plan.counts(ticked: ticked).line }
    /// The counts line, unless it only says again what the title says, such as "1 move" under "Move 1 Item". A line
    /// with more than one part, such as "4 moves · 2 new folders", always shows.
    var shownCountsLine: String {
        let counts = plan.counts(ticked: ticked)
        let repeats: Bool
        switch plan.title {
        case .move(let count): repeats = counts == AgentPlanCounts(moves: count)
        case .copy(let count): repeats = counts == AgentPlanCounts(copies: count)
        case .rename(let count): repeats = counts == AgentPlanCounts(renames: count)
        case .trash(let count): repeats = counts == AgentPlanCounts(trash: count)
        case .organize: repeats = false
        }
        return repeats ? "" : counts.line
    }
    /// Apply works only on a card that waits, for a plan that changes something with these ticks.
    var canApply: Bool { stage == .open && !plan.isEmpty && plan.counts(ticked: ticked).total > 0 }

    // MARK: Groups and rows

    struct GroupRow: Identifiable, Equatable {
        let id: Int
        let title: String
        let isOn: Bool
        let isOpen: Bool
        /// Why the group starts unticked: "Goes to Google Drive", "Leaves iCloud Drive", "Shared". The Trash group's
        /// title says it already.
        let mark: String?
        let rows: [ItemRow]
    }

    struct ItemRow: Identifiable, Equatable {
        let id: Int
        /// The item's name, or "old name → new name" for a rename.
        let name: String
        /// Where the item is now, in words.
        let detail: String
        let tags: [String]
    }

    var groupRows: [GroupRow] {
        plan.groups.map { group in
            GroupRow(id: group.id, title: Self.title(of: group, in: plan), isOn: ticked.contains(group.id),
                     isOpen: opened.contains(group.id), mark: Self.mark(of: group), rows: rows(of: group))
        }
    }

    /// A group's rows without the words its title already says: a tag that is the group's own kind ("Renamed" in a
    /// group of renames), and the folder when every row is directly in the same folder the person added.
    private func rows(of group: AgentPlanGroup) -> [ItemRow] {
        let all = group.steps.filter { plan.steps.indices.contains($0) }.map(row)
        let ownTag: String?
        switch group.kind {
        case .renames: ownTag = AgentText.tagRenamed
        case .trash: ownTag = AgentText.tagTrash
        case .newFolders: ownTag = AgentText.tagNew
        case .moves, .copies: ownTag = nil
        }
        let labels = Set(roots.map { AgentTextEscaper.escape($0.label) })
        let sameFolder = all.count > 1 && Set(all.map(\.detail)).count == 1 && labels.contains(all.first?.detail ?? "")
        return all.map { row in
            ItemRow(id: row.id, name: row.name, detail: sameFolder ? "" : row.detail, tags: row.tags.filter { $0 != ownTag })
        }
    }

    static func title(of group: AgentPlanGroup, in plan: AgentChangePlan) -> String {
        let steps = group.steps.filter { plan.steps.indices.contains($0) }.map { plan.steps[$0] }
        let changes = steps.filter { if case .newFolder = $0 { return false } else { return true } }.count
        switch group.kind {
        case .newFolders: return AgentText.countNewFolders(steps.count)
        case .renames: return AgentText.groupRenames(changes)
        case .moves(let label, _): return AgentText.groupMoves(changes, folder: label)
        case .copies(let label, _): return AgentText.groupCopies(changes, folder: label)
        case .trash: return AgentText.groupTrash(changes)
        }
    }

    static func mark(of group: AgentPlanGroup) -> String? {
        switch group.guardedBy {
        case nil, .trash?: return nil
        case .leaves?: return AgentText.markLeaves(group.place ?? "")
        case .arrives?: return AgentText.markGoesTo(group.place ?? "")
        case .reachesOthers?: return AgentText.chipShared
        }
    }

    private func row(_ index: Int) -> ItemRow {
        var tags: [String] = []
        let name: String, detail: String
        switch plan.steps[index] {
        case .newFolder(_, let parent, let folder):
            name = AgentTextEscaper.escape(folder.value)
            switch parent {
            case .existing(let item): detail = place(of: item.path, including: true)
            case .new(let key): detail = newFolderName(key) ?? ""
            }
            tags.append(AgentText.tagNew)
        case .move(let item, _), .copy(let item, _):
            name = AgentTextEscaper.escape(item.name)
            detail = place(of: item.path, including: false)
            if let holds = item.holds { tags.append(AgentText.rowHolds(holds)) }
        case .rename(let item, let new):
            name = "\(AgentTextEscaper.escape(item.name)) → \(AgentTextEscaper.escape(new.value))"
            detail = place(of: item.path, including: false)
            tags.append(AgentText.tagRenamed)
        case .trash(let item):
            name = AgentTextEscaper.escape(item.name)
            detail = place(of: item.path, including: false)
            if let holds = item.holds { tags.append(AgentText.rowHolds(holds)) }
            tags.append(AgentText.tagTrash)
        }
        if plan.keepsBoth.contains(index) { tags.append(AgentText.tagKeepsBoth) }
        return ItemRow(id: index, name: name, detail: detail, tags: tags)
    }

    private func newFolderName(_ key: String) -> String? {
        for step in plan.steps {
            if case .newFolder(let declared, _, let name) = step, declared == key { return AgentTextEscaper.escape(name.value) }
        }
        return nil
    }

    /// Where an item is, in words: the folder's label, then the folders below it. `including` names the path itself;
    /// otherwise the folder the item is in. The account and the folders above the root are never shown.
    private func place(of path: String, including: Bool) -> String {
        let parts = Self.components(path)
        let folder = including ? parts : Array(parts.dropLast())
        var best: (root: AgentScopeRoot, count: Int)?
        for root in roots {
            let rootParts = Self.components(root.path)
            guard folder.count >= rootParts.count, Array(folder.prefix(rootParts.count)) == rootParts else { continue }
            if rootParts.count > (best?.count ?? -1) { best = (root, rootParts.count) }
        }
        guard let best else { return folder.last.map(AgentTextEscaper.escape) ?? "" }
        return ([best.root.label] + folder.dropFirst(best.count)).map(AgentTextEscaper.escape).joined(separator: " / ")
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    // MARK: Notes

    struct Note: Equatable {
        let text: String
        /// Several reasons for leaving changes out fold into one line; its tooltip lists them.
        let tooltip: String?
    }

    /// Three at most, one a slot. An empty plan with nothing left out says everything is already in place.
    var notes: [Note] {
        if plan.showsNothingToDo { return [Note(text: AgentText.planNothing, tooltip: nil)] }
        let leftOut = plan.notices.filter { $0.slot == 1 }.map(\.text).joined(separator: "\n")
        return plan.cardNotes.prefix(3).map { note in
            if case .leftOutSeveral = note { return Note(text: note.text, tooltip: leftOut) }
            return Note(text: note.text, tooltip: nil)
        }
    }

    /// Every line of the card, as the thread's text holds it.
    var textLines: [String] {
        var lines = [title]
        if !shownCountsLine.isEmpty { lines.append(shownCountsLine) }
        lines += notes.map(\.text)
        lines += groupRows.map(\.title)
        switch stage {
        case .open: if wasRefreshed { lines.append(AgentText.planChanged) }
        case .applying(let line): if !line.isEmpty { lines.append(line) }
        case .applied: break
        case .dismissed: lines.append(AgentText.planDismissed)
        case .replaced: lines.append(AgentText.planReplaced)
        }
        return lines
    }
}

/// The card in the thread: the plan's title and counts, at most three notes, each group with its tick and its full
/// list, and Cancel and Apply. Apply answers a click; Command-Return in the composer is the only key that presses it.
struct AgentPlanCardView: View {
    let card: AgentPlanCard
    let toggle: (Int) -> Void
    let toggleOpen: (Int) -> Void
    let apply: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: card.title).font(.system(size: 13, weight: .semibold))
                if !card.shownCountsLine.isEmpty {
                    Text(verbatim: card.shownCountsLine).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            ForEach(Array(card.notes.enumerated()), id: \.offset) { _, note in
                Text(verbatim: note.text)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(note.tooltip ?? "")
            }
            if card.stage == .open, card.wasRefreshed {
                Text(verbatim: AgentText.planChanged).font(.system(size: 12, weight: .medium))
            }
            ForEach(card.groupRows) { group in
                AgentPlanGroupView(group: group, isEnabled: card.stage == .open,
                                   toggle: { toggle(group.id) }, toggleOpen: { toggleOpen(group.id) })
            }
            footer
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))
    }

    @ViewBuilder private var footer: some View {
        switch card.stage {
        case .open:
            HStack {
                Spacer()
                Button(AgentText.cancel, action: cancel)
                if !card.plan.isEmpty {
                    Button(AgentText.apply, action: apply)
                        .buttonStyle(.borderedProminent)
                        .disabled(!card.canApply)
                }
            }
            .controlSize(.small)
        case .applying(let line):
            HStack(spacing: 6) {
                // The system's own spinner, which keeps still with Reduce Motion on.
                ProgressView().controlSize(.mini)
                Text(verbatim: line).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        case .applied:
            EmptyView()
        case .dismissed:
            Text(verbatim: AgentText.planDismissed).font(.system(size: 12)).foregroundStyle(.secondary)
        case .replaced:
            Text(verbatim: AgentText.planReplaced).font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// One group of a card: its tick, its title, the mark that says why it starts unticked, and its full list.
struct AgentPlanGroupView: View {
    let group: AgentPlanCard.GroupRow
    let isEnabled: Bool
    let toggle: () -> Void
    let toggleOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Toggle(isOn: Binding(get: { group.isOn }, set: { _ in toggle() })) {
                    // The title keeps its own line; the mark that says why it starts unticked sits under it.
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: group.title).font(.system(size: 12)).lineLimit(2)
                        if let mark = group.mark {
                            Text(verbatim: mark)
                                .font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Capsule().fill(Color.primary.opacity(0.10)))
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .disabled(!isEnabled)
                Spacer(minLength: 0)
                Button(action: toggleOpen) {
                    Image(systemName: group.isOpen ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: group.title))
            }
            if group.isOpen {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(group.rows) { row in AgentPlanRowView(row: row) }
                }
                .padding(.leading, 22)
            }
        }
    }
}

/// One item of a group: its name, where it is now, and its tags.
struct AgentPlanRowView: View {
    let row: AgentPlanCard.ItemRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: row.name).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
            if !row.detail.isEmpty {
                Text(verbatim: row.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 0)
            ForEach(row.tags, id: \.self) { tag in
                Text(verbatim: tag).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}
#endif
