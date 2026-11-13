import Foundation
import HelmCore

/// How much one request may do. Helm enforces every limit itself; a model is only told when one is hit.
public struct AgentLimits: Equatable, Sendable {
    /// Model turns in one request, and tool calls in one request and in one turn.
    public var turns: Int, callsPerRequest: Int, callsPerTurn: Int
    /// Entries in one page of a listing and in one request, how deep "all levels" goes, and how many items a find answers with.
    public var entriesPerPage: Int, entriesPerRequest: Int, maxDepth: Int, findResults: Int
    /// Changes and new folders in one plan, plans in one request, and tool calls with bad arguments before the request stops.
    public var planSteps: Int, planNewFolders: Int, plansPerRequest: Int, badArguments: Int
    /// Characters of the person's message that are sent, and of a model's text that are shown for one turn.
    public var messageCharacters: Int, replyCharacters: Int
    /// Seconds for a whole request, and seconds a listing may go without progress.
    public var requestSeconds: Double, listSeconds: Double

    public init(turns: Int, callsPerRequest: Int, callsPerTurn: Int, entriesPerPage: Int, entriesPerRequest: Int,
                maxDepth: Int, findResults: Int, planSteps: Int, planNewFolders: Int, plansPerRequest: Int,
                badArguments: Int, messageCharacters: Int, replyCharacters: Int, requestSeconds: Double, listSeconds: Double) {
        self.turns = turns; self.callsPerRequest = callsPerRequest; self.callsPerTurn = callsPerTurn
        self.entriesPerPage = entriesPerPage; self.entriesPerRequest = entriesPerRequest; self.maxDepth = maxDepth
        self.findResults = findResults; self.planSteps = planSteps; self.planNewFolders = planNewFolders
        self.plansPerRequest = plansPerRequest; self.badArguments = badArguments
        self.messageCharacters = messageCharacters; self.replyCharacters = replyCharacters
        self.requestSeconds = requestSeconds; self.listSeconds = listSeconds
    }

    /// A provider on the internet.
    public static let cloudModel = AgentLimits(
        turns: 12, callsPerRequest: 24, callsPerTurn: 8, entriesPerPage: 500, entriesPerRequest: 5_000, maxDepth: 8,
        findResults: 200, planSteps: 1_000, planNewFolders: 100, plansPerRequest: 2, badArguments: 2,
        messageCharacters: 4_000, replyCharacters: 8_000, requestSeconds: 600, listSeconds: 3)
    /// A model on this Mac: smaller pages, since such a model reads less at once, and more time, since it is slower.
    public static let localModel = AgentLimits(
        turns: 8, callsPerRequest: 12, callsPerTurn: 4, entriesPerPage: 150, entriesPerRequest: 1_000, maxDepth: 8,
        findResults: 60, planSteps: 200, planNewFolders: 40, plansPerRequest: 2, badArguments: 2,
        messageCharacters: 4_000, replyCharacters: 8_000, requestSeconds: 1_200, listSeconds: 3)

    /// The limits for work in a folder of this kind of place. A cloud folder and a server are slower and riskier
    /// than a disk in the Mac, so less is listed and less is changed at once, and a listing is given longer.
    /// A limit that is already lower stays as it is.
    public func adjusted(for kind: StorageKind) -> AgentLimits {
        var limits = self
        switch kind {
        case .thisMac, .external:
            break
        case .iCloud, .cloud:
            limits.maxDepth = min(maxDepth, 6)
            limits.planSteps = min(planSteps, 500)
            limits.listSeconds = 8
        case .network:
            limits.maxDepth = min(maxDepth, 4)
            limits.entriesPerRequest = min(entriesPerRequest, 2_000)
            limits.planSteps = min(planSteps, 200)
            limits.listSeconds = 10
        }
        return limits
    }

    /// These limits with a listing's time set to `listSeconds`. A session applies this last, after `adjusted(for:)`,
    /// when a fixture run asks for short waits.
    public func scaled(listSeconds: Double) -> AgentLimits {
        var limits = self
        limits.listSeconds = max(0, listSeconds)
        return limits
    }

    /// Folders one window's AI mode may use at once: the tab's folder and seven the person added.
    public static let roots = 8
    /// Requests in one thread, and bytes of its history, before Helm starts the thread over.
    public static let threadRequests = 30
    public static let threadBytes = 8_000_000
    public static let handlesPerThread = 20_000
    /// More items than this changed in one place that is known to be shared need the person's own tick.
    public static let bulkShared = 25
    /// How deep new folders may nest inside each other in one plan.
    public static let newFolderLevels = 4
    public static let callIDCharacters = 128
    /// A folder's items are counted up to here. The card writes "1,000+" for a folder that reaches it.
    public static let holdsCap = 1_000
    /// Entries looked at to find whether a folder holds a file that isn't downloaded.
    public static let datalessWalk = 2_000
    /// How long any one question to the disk may take.
    public static let diskSeconds: Double = 2
}
