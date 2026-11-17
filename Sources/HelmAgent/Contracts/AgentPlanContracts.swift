import Foundation
import HelmCore

/// An item a plan changes, as it was when the plan was checked.
public struct AgentPlanItem: Hashable, Sendable {
    public let handle: String, rootAlias: String, path: String, name: String
    public let kind: FileEntryKind
    public let identity: FileObjectIdentity?
    public let isDataless: Bool
    /// How many items a folder holds directly, counted when the plan was checked. Nil for anything but a folder.
    public let holds: Int?
    public init(handle: String, rootAlias: String, path: String, name: String, kind: FileEntryKind,
                identity: FileObjectIdentity?, isDataless: Bool, holds: Int? = nil) {
        self.handle = handle; self.rootAlias = rootAlias; self.path = path; self.name = name; self.kind = kind
        self.identity = identity; self.isDataless = isDataless; self.holds = holds
    }
}

/// Where a step puts something: a folder that exists, or one the same plan makes.
public enum AgentPlanTarget: Hashable, Sendable { case existing(AgentPlanItem), new(key: String) }

/// One change. A renamed file keeps its extension.
public enum AgentPlanStep: Hashable, Sendable {
    case newFolder(key: String, parent: AgentPlanTarget, name: ValidFileName)
    /// A file the plan makes, holding the whole text the model wrote. Its name ends in one of
    /// `AgentNewName.newFileExtensions`; an RTF or Word file is made from the text when the plan is applied.
    case newFile(parent: AgentPlanTarget, name: ValidFileName, text: String)
    case move(AgentPlanItem, to: AgentPlanTarget)
    case copy(AgentPlanItem, to: AgentPlanTarget)
    case rename(AgentPlanItem, to: ValidFileName)
    case trash(AgentPlanItem)
}

/// Why a group of steps starts unticked: it removes something, or it puts files where other people or other devices
/// see them. When two apply to one step, the first in this order wins.
public enum AgentPlanGuard: String, Sendable, CaseIterable { case trash, leaves, arrives, reachesOthers }

/// Steps the person ticks or unticks together. Steps of one kind and destination with different guards or places
/// make separate groups.
public struct AgentPlanGroup: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        /// New folders that nothing else in the plan goes into.
        case newFolders
        /// New files, by the folder they are made in.
        case newFiles(toLabel: String, isNew: Bool)
        case renames
        case moves(toLabel: String, isNew: Bool)
        case copies(toLabel: String, isNew: Bool)
        case trash
    }
    public let id: Int
    public let kind: Kind
    /// Indexes into the plan's steps. A step is in exactly one group.
    public let steps: [Int]
    /// Nil for an ordinary group. A guard is a property of a group, not a kind of group.
    public let guardedBy: AgentPlanGuard?
    /// The place the group's mark names, such as "Google Drive" or "Server".
    public let place: String?
    /// Whether the group's tick starts on.
    public var startsOn: Bool { guardedBy == nil }
    public init(id: Int, kind: Kind, steps: [Int], guardedBy: AgentPlanGuard? = nil, place: String? = nil) {
        self.id = id; self.kind = kind; self.steps = steps; self.guardedBy = guardedBy; self.place = place
    }
}

/// What a plan is called, on its card and in the Edit menu's Undo.
public enum AgentPlanTitle: Hashable, Sendable {
    case organize(rootLabel: String)
    case move(Int)
    case copy(Int)
    case rename(Int)
    case trash(Int)
    case create(Int)
}

/// A line under a plan. A card shows one line a slot: what was left out (slot 1), what can't be undone (slot 2),
/// and what syncs or is shared (slot 3).
public enum AgentPlanNotice: Hashable, Sendable {
    case notAllowed(Int), notDownloaded(Int), foldersNotLoaded(Int), noTrash(place: String), readOnly(place: String)
    /// Several of the lines above folded into one. Only `AgentChangePlan.cardNotes` makes this.
    case leftOutSeveral(Int)
    case cantUndo(place: String)
    case syncs, shared(place: String), syncsMaybeShared
}

/// How many changes of each kind a plan makes.
public struct AgentPlanCounts: Equatable, Sendable {
    public var moves: Int, copies: Int, newFiles: Int, newFolders: Int, renames: Int, trash: Int
    public init(moves: Int = 0, copies: Int = 0, newFiles: Int = 0, newFolders: Int = 0, renames: Int = 0, trash: Int = 0) {
        self.moves = moves; self.copies = copies; self.newFiles = newFiles; self.newFolders = newFolders
        self.renames = renames; self.trash = trash
    }
}

/// A plan of changes that Helm checked. Everything on its card is built by Helm from the checked steps; nothing a
/// model wrote reaches the card's own words.
public struct AgentChangePlan: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let title: AgentPlanTitle
    public let steps: [AgentPlanStep]
    public let groups: [AgentPlanGroup]
    public let notices: [AgentPlanNotice]
    /// Steps whose name is taken where they are going. Both items are kept.
    public let keepsBoth: Set<Int>
    /// How many changes were left out, by the reason.
    public let leftOut: [AgentToolCode: Int]
    public init(id: UUID = UUID(), title: AgentPlanTitle, steps: [AgentPlanStep], groups: [AgentPlanGroup],
                notices: [AgentPlanNotice], keepsBoth: Set<Int> = [], leftOut: [AgentToolCode: Int]) {
        self.id = id; self.title = title; self.steps = steps; self.groups = groups; self.notices = notices
        self.keepsBoth = keepsBoth; self.leftOut = leftOut
    }
}

/// What a model asked for in `propose_changes`, decoded and not yet trusted: every item is still only a handle or
/// a name.
public struct AgentProposedChanges: Equatable, Sendable {
    public struct NewFolder: Equatable, Sendable {
        public let key, parent, name: String
        public init(key: String, parent: String, name: String) {
            self.key = key; self.parent = parent; self.name = name
        }
    }
    public struct Transfer: Equatable, Sendable {
        public let items: [String]
        public let allIn: String
        public let to: String
        public init(items: [String], allIn: String, to: String) {
            self.items = items; self.allIn = allIn; self.to = to
        }
    }
    public struct Rename: Equatable, Sendable {
        public let item, name: String
        public init(item: String, name: String) {
            self.item = item; self.name = name
        }
    }
    /// A file to make: the folder it goes in (an id or a new-folder key), its name, and the whole text it holds.
    public struct NewFile: Equatable, Sendable {
        public let parent, name, text: String
        public init(parent: String, name: String, text: String) {
            self.parent = parent; self.name = name; self.text = text
        }
    }
    public let newFolders: [NewFolder], newFiles: [NewFile], moves: [Transfer], copies: [Transfer], renames: [Rename],
               trash: [String]
    public init(newFolders: [NewFolder], newFiles: [NewFile] = [], moves: [Transfer], copies: [Transfer], renames: [Rename],
                trash: [String]) {
        self.newFolders = newFolders; self.newFiles = newFiles; self.moves = moves; self.copies = copies
        self.renames = renames; self.trash = trash
    }
}

/// What checking a proposal came to.
public enum AgentPlanVerdict: Sendable {
    case plan(AgentChangePlan)
    /// The whole call was refused: `too_many` or `bad_arguments`.
    case refused(AgentToolCode)
    case nothingToDo(leftOut: [AgentToolCode: Int])
}

/// What looking at a plan again, right before it runs, came to.
public enum AgentRecheck: Equatable, Sendable { case ok, changed(AgentChangePlan), notResponding(label: String), disconnected(label: String) }

/// Checks what a model proposed against the folders it may use and the disk as it is.
public protocol AgentPlanValidating: Sendable {
    func validate(_ proposal: AgentProposedChanges, scope: any AgentHandleResolving, disk: any AgentDisk,
                  limits: AgentLimits) async -> AgentPlanVerdict
    func recheck(_ plan: AgentChangePlan, ticked: Set<Int>, scope: any AgentHandleResolving,
                 disk: any AgentDisk) async -> AgentRecheck
}

/// What a session answers when the card asks to apply a plan.
public enum AgentApplyTicket: Equatable, Sendable {
    /// Go ahead, with the session's own copy of the plan. The same id can't be applied again.
    case go(AgentChangePlan)
    /// Something changed, so nothing may run. This is the new pending plan, and its ticks start at `defaultTicked`.
    case changed(AgentChangePlan)
    case notResponding(label: String), disconnected(label: String)
    /// Not the pending plan's id, already used, or a tick that isn't one of its groups.
    case refused
}
