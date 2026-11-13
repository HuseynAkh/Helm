import Foundation
import HelmCore

/// What a change may do in the places it touches: on this Mac, in iCloud Drive or another provider's folder, on a
/// server or on an external disk. The rules are Helm's own and are kept when the plan arrives and again before it
/// runs; the model is told them only as a courtesy.
///
/// A step is left out when it can't be done safely there (a place that can only be viewed, a Trash that isn't
/// there, the bytes of a file that isn't downloaded). Otherwise its group may start unticked, with a mark saying
/// why: it goes to the Trash, it leaves a place others see, or it arrives in one.
public enum AgentPlaceRules {
    public struct Ruling: Equatable, Sendable {
        /// Why the step is left out of the plan. Nil when it stays.
        public var leftOut: AgentToolCode?
        /// Why the step's group starts unticked. Nil for an ordinary step.
        public var guardedBy: AgentPlanGuard?
        /// The place the guard's mark names, such as "iCloud Drive".
        public var place: String?
        /// The lines the step adds under the plan.
        public var notices: [AgentPlanNotice]
        public init(leftOut: AgentToolCode? = nil, guardedBy: AgentPlanGuard? = nil, place: String? = nil,
                    notices: [AgentPlanNotice] = []) {
            self.leftOut = leftOut; self.guardedBy = guardedBy; self.place = place; self.notices = notices
        }
    }

    /// The ruling for one step. `source` holds the facts of the item's own folder (a file's parent; a folder
    /// itself), or for a new folder the folder it is made in. `destination` holds the facts of the folder a move or
    /// a copy goes into. `holdsDataless` says the item is a file that isn't downloaded, or a folder that holds one.
    ///
    /// The bulk guard, for many changes in a place others share, needs the whole plan and is decided afterwards by
    /// `bulkGuarded`.
    public static func rule(for step: AgentPlanStep, source: StorageFacts, destination: StorageFacts?,
                            holdsDataless: Bool) -> Ruling {
        let target = destination ?? source
        // A place that doesn't answer can't be checked, so nothing there is planned.
        if !source.isResponding || !target.isResponding { return Ruling(leftOut: .not_responding) }
        switch step {
        case .newFolder:
            if target.isReadOnly { return readOnly(target) }
            return Ruling(notices: undoNotice(madeIn: target) + reachNotices(target))

        case .rename:
            if source.isReadOnly { return readOnly(source) }
            return Ruling(notices: reachNotices(source))

        case .trash:
            if source.isReadOnly { return readOnly(source) }
            // Nothing is ever deleted: where there is no Trash, nothing is taken away.
            guard source.trash == .yes else { return Ruling(leftOut: .no_trash, notices: [.noTrash(place: source.name)]) }
            return Ruling(guardedBy: .trash, notices: reachNotices(source))

        case .copy(let item, _):
            if target.isReadOnly { return readOnly(target) }
            if holdsDataless || item.isDataless { return Ruling(leftOut: .not_downloaded) }
            var ruling = Ruling(notices: undoNotice(madeIn: target) + reachNotices(target))
            if arrives(from: source, in: target) { ruling.guardedBy = .arrives; ruling.place = target.name }
            return ruling

        case .move(let item, _):
            if source.isReadOnly { return readOnly(source) }
            if target.isReadOnly { return readOnly(target) }
            if (holdsDataless || item.isDataless) && needsBytes(step, source: source, destination: target) {
                return Ruling(leftOut: .not_downloaded)
            }
            // Taking an item off another disk removes it there, which can't be undone where there is no Trash.
            if source.trash != .yes && source.volumeRoot != target.volumeRoot {
                return Ruling(leftOut: .no_trash, notices: [.noTrash(place: source.name)])
            }
            var notices = reachNotices(source)
            // The destination's own reach, even inside one place: a shared folder in iCloud Drive says so.
            if target != source {
                for notice in reachNotices(target) where !notices.contains(notice) { notices.append(notice) }
            }
            var ruling = Ruling(notices: notices)
            if target.placeKey != source.placeKey && source.isSeenElsewhere {
                ruling.guardedBy = .leaves; ruling.place = source.name
            } else if arrives(from: source, in: target) {
                ruling.guardedBy = .arrives; ruling.place = target.name
            }
            return ruling
        }
    }

    /// Whether the step needs the item's bytes: a copy always, and a move when it leaves its place or its disk,
    /// since that is a copy and then a removal.
    public static func needsBytes(_ step: AgentPlanStep, source: StorageFacts, destination: StorageFacts?) -> Bool {
        switch step {
        case .copy: return true
        case .move:
            let target = destination ?? source
            return target.placeKey != source.placeKey || target.volumeRoot != source.volumeRoot
        case .newFolder, .rename, .trash: return false
        }
    }

    /// One change counted against a place for the bulk guard.
    struct PlaceChange: Equatable, Sendable {
        /// The step's index in the plan.
        var step: Int
        /// The facts of the place the step changes.
        var place: StorageFacts
        /// The item changed is a folder that already exists, so everything in it is changed too.
        var isFolder: Bool
    }

    /// The steps that need the bulk guard: in a place known to be shared, more than `AgentLimits.bulkShared`
    /// changes, or any change to a folder, puts them all in front of other people. Each of those steps is guarded,
    /// and the place it names is the shared place.
    static func bulkGuarded(_ changes: [PlaceChange]) -> [Int: String] {
        var byPlace: [String: [PlaceChange]] = [:]
        var order: [String] = []
        for change in changes where change.place.sharingIsKnown {
            if byPlace[change.place.placeKey] == nil { order.append(change.place.placeKey) }
            byPlace[change.place.placeKey, default: []].append(change)
        }
        var guarded: [Int: String] = [:]
        for key in order {
            guard let inPlace = byPlace[key] else { continue }
            let steps = Set(inPlace.map(\.step))
            guard steps.count > AgentLimits.bulkShared || inPlace.contains(where: \.isFolder) else { continue }
            for change in inPlace where guarded[change.step] == nil { guarded[change.step] = change.place.name }
        }
        return guarded
    }

    // MARK: Pieces

    private static func readOnly(_ facts: StorageFacts) -> Ruling {
        Ruling(leftOut: .read_only, notices: [.readOnly(place: facts.name)])
    }

    /// Something put into `target` from another place that other devices or other people see.
    private static func arrives(from source: StorageFacts, in target: StorageFacts) -> Bool {
        target.placeKey != source.placeKey && target.isSeenElsewhere
    }

    /// What a change in this place reaches: everyone who uses it when sharing is known, the person's devices and
    /// anyone it is shared with when the provider doesn't say, or the person's devices alone.
    static func reachNotices(_ facts: StorageFacts) -> [AgentPlanNotice] {
        if facts.sharingIsKnown { return [.shared(place: facts.name)] }
        if facts.syncs { return [facts.shared == .unknown ? .syncsMaybeShared : .syncs] }
        return []
    }

    /// Undo of something made in a place takes it away again, which needs a Trash there.
    private static func undoNotice(madeIn facts: StorageFacts) -> [AgentPlanNotice] {
        facts.trash == .yes ? [] : [.cantUndo(place: facts.name)]
    }
}
